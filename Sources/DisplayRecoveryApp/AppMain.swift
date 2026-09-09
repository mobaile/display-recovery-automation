import AppKit
import Combine
import DisplayRecoveryCore
import DisplayRecoveryMac

@main
@MainActor
final class DisplayRecoveryAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = DisplayRecoveryAppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var mainWindowController: ScreenPilotWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "ScreenPilot"
            button.toolTip = "ScreenPilot Display Control"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        rebuildMenu()

        if CommandLine.arguments.contains("--open") {
            openMainWindow()
        }

        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.mainWindowController?.refresh()
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        observation?.cancel()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func openMainWindow() {
        if mainWindowController == nil {
            mainWindowController = ScreenPilotWindowController(model: model, onClose: { [weak self] in
                self?.checkActivationPolicy()
            })
        }
        NSApp.setActivationPolicy(.regular)
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openSettingsWindow() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(model: model, onClose: { [weak self] in
                self?.checkActivationPolicy()
            })
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func checkActivationPolicy() {
        let mainVisible = mainWindowController?.window?.isVisible == true
        let settingsVisible = settingsWindowController?.window?.isVisible == true
        if !mainVisible && !settingsVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let openItem = NSMenuItem(title: "Open ScreenPilot…", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ScreenPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            openMainWindow()
            return
        }

        let isRightClick = event.type == .rightMouseUp ||
            event.type == .rightMouseDown ||
            ((event.type == .leftMouseUp || event.type == .leftMouseDown) && event.modifierFlags.contains(.control))

        if isRightClick {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
        } else {
            openMainWindow()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }
}

// MARK: - Main Window Controller

@MainActor
private final class ScreenPilotWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    // 1. 状态区
    private let displaySummaryLabel = NSTextField(labelWithString: "")
    private let rolesLabel = NSTextField(labelWithString: "")

    // 2. 按钮区
    private let turnOffButton = NSButton(title: "Turn Off", target: nil, action: nil)
    private let turnOnButton = NSButton(title: "Turn On", target: nil, action: nil)
    private let lowerResButton = NSButton(title: "Lower Resolution", target: nil, action: nil)
    private let restoreFullResButton = NSButton(title: "Restore Full Resolution", target: nil, action: nil)
    private let checkStatusButton = NSButton(title: "Check Status", target: nil, action: nil)
    private let verifyBothScreensButton = NSButton(title: "Verify Both Screens", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop", target: nil, action: nil)

    // 3. 日志区
    private let logTextView = NSTextView()
    private let logScrollView = NSScrollView()
    private let copyLogButton = NSButton(title: "Copy Log", target: nil, action: nil)
    private let exportLogButton = NSButton(title: "Export Log", target: nil, action: nil)

    private var screenChangeObserver: NSObjectProtocol?
    private var onClose: (() -> Void)?

    init(model: AppModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenPilot"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 580, height: 500)
        window.setContentSize(NSSize(width: 680, height: 620))
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        refresh()

        // 监听显示器拓扑变化，确保窗口在屏幕拔出后依然在有效可视区域内
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.ensureWindowOnAvailableScreen()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    override func showWindow(_ sender: Any?) {
        if window?.isMiniaturized == true {
            window?.deminiaturize(sender)
        }
        window?.makeKeyAndOrderFront(sender)
        super.showWindow(sender)
        ensureWindowOnAvailableScreen()
        refresh()
        Task { [weak self] in
            await self?.model.syncDeviceStates()
        }
    }

    private func ensureWindowOnAvailableScreen() {
        guard let window else { return }
        let currentFrame = window.frame
        let isVisibleOnAnyScreen = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(currentFrame)
        }
        if !isVisibleOnAnyScreen {
            if let mainScreen = NSScreen.main {
                let screenFrame = mainScreen.visibleFrame
                let newOrigin = NSPoint(
                    x: screenFrame.origin.x + (screenFrame.width - currentFrame.width) / 2,
                    y: screenFrame.origin.y + (screenFrame.height - currentFrame.height) / 2
                )
                window.setFrameOrigin(newOrigin)
            } else {
                window.center()
            }
        }
    }

    func refresh() {
        // 显示器摘要
        if model.snapshots.isEmpty {
            displaySummaryLabel.stringValue = "Displays: No active displays detected."
        } else {
            let lines = model.snapshots.map { s in
                let name = s.fingerprint.displayName.isEmpty ? "Display \(s.displayID)" : s.fingerprint.displayName
                let modeDesc = s.mode?.shortDescription ?? "Unknown mode"
                let builtin = s.isBuiltin ? " [Builtin]" : ""
                return "• \(name)\(builtin): \(modeDesc)"
            }
            displaySummaryLabel.stringValue = lines.joined(separator: "\n")
        }

        rolesLabel.stringValue = "ANT display: \(model.roleName(.powerControlled))   |   MSI display: \(model.roleName(.modeSwitch))"

        // 按钮启用与状态呈现
        let busy = model.isBusy

        // 1. ANT display 状态表现
        switch model.antState {
        case .on:
            applyStatusStyle(to: turnOnButton, isActive: true, isBusy: busy)
            applyStatusStyle(to: turnOffButton, isActive: false, isBusy: busy)
        case .off:
            applyStatusStyle(to: turnOffButton, isActive: true, isBusy: busy)
            applyStatusStyle(to: turnOnButton, isActive: false, isBusy: busy)
        case .unknown:
            applyStatusStyle(to: turnOnButton, isActive: false, isBusy: busy)
            applyStatusStyle(to: turnOffButton, isActive: false, isBusy: busy)
        }

        // 2. MSI display 状态表现
        switch model.msiState {
        case .fullResolution:
            applyStatusStyle(to: restoreFullResButton, isActive: true, isBusy: busy)
            applyStatusStyle(to: lowerResButton, isActive: false, isBusy: busy)
        case .lowerResolution:
            applyStatusStyle(to: lowerResButton, isActive: true, isBusy: busy)
            applyStatusStyle(to: restoreFullResButton, isActive: false, isBusy: busy)
        case .unknown:
            applyStatusStyle(to: restoreFullResButton, isActive: false, isBusy: busy)
            applyStatusStyle(to: lowerResButton, isActive: false, isBusy: busy)
        }

        // 3. Inspection 与辅助按钮
        checkStatusButton.isEnabled = !busy
        verifyBothScreensButton.isEnabled = !busy

        stopButton.isEnabled = busy
        stopButton.contentTintColor = busy ? .systemRed : .disabledControlTextColor

        // 更新日志视图
        updateLogText()
    }

    private func applyStatusStyle(to button: NSButton, isActive: Bool, isBusy: Bool) {
        if isActive {
            button.bezelColor = .systemGreen
            button.isEnabled = false
            button.toolTip = "当前生效状态"
        } else {
            button.bezelColor = nil
            button.isEnabled = !isBusy
            button.toolTip = nil
        }
    }

    private func updateLogText() {
        let currentLogs = model.logs.joined(separator: "\n")
        guard logTextView.string != currentLogs else { return }

        let clipView = logScrollView.contentView
        let wasAtBottom = (clipView.bounds.origin.y + clipView.bounds.height) >= (logTextView.frame.height - 30)

        logTextView.string = currentLogs

        if wasAtBottom {
            logTextView.scrollToEndOfDocument(nil)
        }
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        // 1. Status Section
        let statusBox = NSStackView()
        statusBox.orientation = .vertical
        statusBox.alignment = .leading
        statusBox.spacing = 6

        let appTitle = NSTextField(labelWithString: "ScreenPilot")
        appTitle.font = .systemFont(ofSize: 18, weight: .bold)
        statusBox.addArrangedSubview(appTitle)

        displaySummaryLabel.font = .systemFont(ofSize: 11)
        displaySummaryLabel.maximumNumberOfLines = 5
        displaySummaryLabel.lineBreakMode = .byWordWrapping
        statusBox.addArrangedSubview(displaySummaryLabel)

        rolesLabel.font = .systemFont(ofSize: 11)
        rolesLabel.textColor = .secondaryLabelColor
        statusBox.addArrangedSubview(rolesLabel)
        rootStack.addArrangedSubview(statusBox)

        // 2. Actions Section
        let actionsBox = NSStackView()
        actionsBox.orientation = .vertical
        actionsBox.alignment = .leading
        actionsBox.spacing = 8

        let actionsTitle = NSTextField(labelWithString: "Actions")
        actionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        actionsBox.addArrangedSubview(actionsTitle)

        // Row 1: ANT display controls
        let antRow = NSStackView()
        antRow.orientation = .horizontal
        antRow.spacing = 8
        let antLabel = NSTextField(labelWithString: "ANT display:")
        antLabel.font = .systemFont(ofSize: 12, weight: .medium)
        antLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        configureButton(turnOffButton, title: "Turn Off", action: #selector(turnOffClicked))
        configureButton(turnOnButton, title: "Turn On", action: #selector(turnOnClicked))
        antRow.addArrangedSubview(antLabel)
        antRow.addArrangedSubview(turnOffButton)
        antRow.addArrangedSubview(turnOnButton)
        actionsBox.addArrangedSubview(antRow)

        // Row 2: MSI display controls
        let msiRow = NSStackView()
        msiRow.orientation = .horizontal
        msiRow.spacing = 8
        let msiLabel = NSTextField(labelWithString: "MSI display:")
        msiLabel.font = .systemFont(ofSize: 12, weight: .medium)
        msiLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        configureButton(lowerResButton, title: "Lower Resolution", action: #selector(lowerResClicked))
        configureButton(restoreFullResButton, title: "Restore Full Resolution", action: #selector(restoreFullResClicked))
        msiRow.addArrangedSubview(msiLabel)
        msiRow.addArrangedSubview(lowerResButton)
        msiRow.addArrangedSubview(restoreFullResButton)
        actionsBox.addArrangedSubview(msiRow)

        // Row 3: Inspection controls + Stop
        let checkRow = NSStackView()
        checkRow.orientation = .horizontal
        checkRow.spacing = 8
        let checkLabel = NSTextField(labelWithString: "Inspection:")
        checkLabel.font = .systemFont(ofSize: 12, weight: .medium)
        checkLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        configureButton(checkStatusButton, title: "Check Status", action: #selector(checkStatusClicked))
        configureButton(verifyBothScreensButton, title: "Verify Both Screens", action: #selector(verifyBothScreensClicked))
        configureButton(stopButton, title: "Stop", action: #selector(stopClicked))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false

        checkRow.addArrangedSubview(checkLabel)
        checkRow.addArrangedSubview(checkStatusButton)
        checkRow.addArrangedSubview(verifyBothScreensButton)
        checkRow.addArrangedSubview(stopButton)
        actionsBox.addArrangedSubview(checkRow)

        rootStack.addArrangedSubview(actionsBox)

        // 3. Execution Log Section
        let logHeaderRow = NSStackView()
        logHeaderRow.orientation = .horizontal
        logHeaderRow.spacing = 10
        let logTitle = NSTextField(labelWithString: "Execution Log")
        logTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        configureButton(copyLogButton, title: "Copy Log", action: #selector(copyLogClicked))
        configureButton(exportLogButton, title: "Export Log", action: #selector(exportLogClicked))
        logHeaderRow.addArrangedSubview(logTitle)
        logHeaderRow.addArrangedSubview(copyLogButton)
        logHeaderRow.addArrangedSubview(exportLogButton)
        rootStack.addArrangedSubview(logHeaderRow)

        // Log text view
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logTextView.autoresizingMask = [.width]

        logScrollView.documentView = logTextView
        logScrollView.hasVerticalScroller = true
        logScrollView.hasHorizontalScroller = false
        logScrollView.borderType = .bezelBorder
        logScrollView.translatesAutoresizingMaskIntoConstraints = false

        rootStack.addArrangedSubview(logScrollView)

        contentView.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            contentView.topAnchor.constraint(equalTo: rootStack.topAnchor, constant: 18),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: 18),

            rootStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 580),
            logScrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            logScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
    }

    private func configureButton(_ button: NSButton, title: String, action: Selector) {
        button.title = title
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .regular
    }

    // MARK: - Button Actions

    @objc private func turnOffClicked() {
        guard model.antState != .off else { return }
        model.execute(.powerOff)
    }

    @objc private func turnOnClicked() {
        guard model.antState != .on else { return }
        model.execute(.powerOn)
    }

    @objc private func lowerResClicked() {
        guard model.msiState != .lowerResolution else { return }
        model.execute(.lowerResolution)
    }

    @objc private func restoreFullResClicked() {
        guard model.msiState != .fullResolution else { return }
        model.execute(.restoreFullResolution)
    }

    @objc private func checkStatusClicked() {
        model.execute(.checkStatus)
    }

    @objc private func verifyBothScreensClicked() {
        model.execute(.verifyBothScreens)
    }

    @objc private func stopClicked() {
        model.stop()
    }

    @objc private func copyLogClicked() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logTextView.string, forType: .string)
    }

    @objc private func exportLogClicked() {
        guard let url = model.exportRedactedLog() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
