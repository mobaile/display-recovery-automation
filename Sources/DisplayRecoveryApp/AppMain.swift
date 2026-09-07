import AppKit
import Combine
import DisplayRecoveryCore
import DisplayRecoveryMac

@main
@MainActor
final class DisplayRecoveryAppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem!
    private var menu = NSMenu()
    private var panelController: RecoveryPanelController?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "双屏"
        statusItem.button?.toolTip = "双显示器自动恢复"
        rebuildMenu()

        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.rebuildMenu()
                self?.panelController?.refresh()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        observation?.cancel()
    }

    @objc private func openPanel() {
        if panelController == nil {
            panelController = RecoveryPanelController(model: model)
        }
        panelController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleAutomaticRecovery(_ sender: NSMenuItem) {
        model.automaticRecoveryEnabled = sender.state != .on
        rebuildMenu()
    }

    @objc private func triggerRecovery() {
        model.triggerRecovery()
    }

    @objc private func refresh() {
        Task { @MainActor in await model.refresh() }
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let title = NSMenuItem(title: "双显示器自动恢复", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let status = NSMenuItem(title: model.recoveryStatus.message, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if let error = model.recoveryStatus.lastError ?? model.lastError {
            let errorItem = NSMenuItem(title: "最近失败：\(error)", action: nil, keyEquivalent: "")
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        if model.snapshots.isEmpty {
            let item = NSMenuItem(title: "显示器：无在线设备", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for snapshot in model.snapshots {
                let name = snapshot.fingerprint.displayName.isEmpty
                    ? "显示器 \(snapshot.displayID)"
                    : snapshot.fingerprint.displayName
                let mode = snapshot.mode?.shortDescription ?? "未知模式"
                let item = NSMenuItem(title: "显示器：\(name) · \(mode)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        let plug = NSMenuItem(title: "插座：\(model.plugStateText)", action: nil, keyEquivalent: "")
        plug.isEnabled = false
        menu.addItem(plug)

        let hid = NSMenuItem(
            title: "MSI HID：\(model.msiStatus?.connected == true ? "已连接" : "未连接")",
            action: nil,
            keyEquivalent: ""
        )
        hid.isEnabled = false
        menu.addItem(hid)
        menu.addItem(.separator())

        let automatic = NSMenuItem(title: "自动恢复", action: #selector(toggleAutomaticRecovery(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = model.automaticRecoveryEnabled ? .on : .off
        menu.addItem(automatic)

        let recover = NSMenuItem(title: "立即恢复双屏", action: #selector(triggerRecovery), keyEquivalent: "r")
        recover.target = self
        recover.isEnabled = !model.recoveryStatus.recoveryInProgress
        menu.addItem(recover)

        let panel = NSMenuItem(title: "打开控制面板…", action: #selector(openPanel), keyEquivalent: ",")
        panel.target = self
        menu.addItem(panel)

        let refresh = NSMenuItem(title: "刷新", action: #selector(refresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }
}

@MainActor
private final class RecoveryPanelController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let statusLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let displaysLabel = NSTextField(labelWithString: "")
    private let roleButtonsStack = NSStackView()
    private let rolesLabel = NSTextField(labelWithString: "")
    private let plugLabel = NSTextField(labelWithString: "")
    private let hidLabel = NSTextField(labelWithString: "")
    private let hostField = NSTextField(string: "")
    private let modelField = NSTextField(string: "")
    private let tokenField = NSSecureTextField(string: "")
    private let automaticButton = NSButton(checkboxWithTitle: "自动恢复", target: nil, action: nil)

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "双显示器自动恢复"
        window.center()
        super.init(window: window)
        window.delegate = self
        buildView()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        refresh()
    }

    func refresh() {
        statusLabel.stringValue = "状态：\(model.recoveryStatus.message)"
        errorLabel.stringValue = (model.recoveryStatus.lastError ?? model.lastError).map { "最近失败：\($0)" } ?? ""
        displaysLabel.stringValue = displaySummary()
        rebuildRoleButtons()
        rolesLabel.stringValue = "插座屏：\(model.roleName(.powerControlled))\n模式屏：\(model.roleName(.modeSwitch))"
        plugLabel.stringValue = "插座：\(model.plugStateText)"
        hidLabel.stringValue = "MSI HID：\(model.msiStatus?.connected == true ? "已连接" : "未连接") · 模式：\(model.msiStatus?.mode.rawValue ?? "未知")"
        hostField.stringValue = model.appConfiguration.plug.host
        modelField.stringValue = model.appConfiguration.plug.model
        automaticButton.state = model.automaticRecoveryEnabled ? .on : .off
    }

    private func rebuildRoleButtons() {
        roleButtonsStack.arrangedSubviews.forEach { view in
            roleButtonsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        roleButtonsStack.orientation = .vertical
        roleButtonsStack.alignment = .leading
        roleButtonsStack.spacing = 5
        for snapshot in model.snapshots {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let name = snapshot.fingerprint.displayName.isEmpty
                ? "显示器 \(snapshot.displayID)"
                : snapshot.fingerprint.displayName
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11)
            label.widthAnchor.constraint(equalToConstant: 210).isActive = true
            row.addArrangedSubview(label)

            let power = NSButton(title: "设为插座屏", target: self, action: #selector(assignPowerDisplay(_:)))
            power.tag = Int(snapshot.displayID)
            power.bezelStyle = .rounded
            power.controlSize = .small
            row.addArrangedSubview(power)

            let mode = NSButton(title: "设为模式屏", target: self, action: #selector(assignModeDisplay(_:)))
            mode.tag = Int(snapshot.displayID)
            mode.bezelStyle = .rounded
            mode.controlSize = .small
            row.addArrangedSubview(mode)
            roleButtonsStack.addArrangedSubview(row)
        }
    }

    private func displaySummary() -> String {
        guard !model.snapshots.isEmpty else { return "显示器：当前没有在线设备" }
        return model.snapshots.map { snapshot in
            let name = snapshot.fingerprint.displayName.isEmpty
                ? "显示器 \(snapshot.displayID)"
                : snapshot.fingerprint.displayName
            let mode = snapshot.mode?.shortDescription ?? "未知模式"
            return "显示器：\(name) · \(mode)"
        }.joined(separator: "\n")
    }

    private func buildView() {
        guard let contentView = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "双显示器自动恢复")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        stack.addArrangedSubview(heading)
        for label in [statusLabel, errorLabel, displaysLabel, rolesLabel, plugLabel, hidLabel] {
            label.font = .systemFont(ofSize: 12)
            label.maximumNumberOfLines = 4
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(label)
        }
        stack.addArrangedSubview(roleButtonsStack)

        let configurationBox = NSStackView()
        configurationBox.orientation = .vertical
        configurationBox.alignment = .leading
        configurationBox.spacing = 6
        let boxTitle = NSTextField(labelWithString: "插座配置（token 仅保存到 Keychain）")
        boxTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        configurationBox.addArrangedSubview(boxTitle)
        configurationBox.addArrangedSubview(labeledField("型号", field: modelField))
        configurationBox.addArrangedSubview(labeledField("IP 地址", field: hostField))
        configurationBox.addArrangedSubview(labeledField("Token", field: tokenField))
        stack.addArrangedSubview(configurationBox)

        automaticButton.target = self
        automaticButton.action = #selector(toggleAutomatic)
        stack.addArrangedSubview(automaticButton)

        let actions = NSStackView()
        actions.spacing = 8
        let save = NSButton(title: "保存设置", target: self, action: #selector(saveSettings))
        save.bezelStyle = .rounded
        let recover = NSButton(title: "立即恢复双屏", target: self, action: #selector(triggerRecovery))
        recover.bezelStyle = .rounded
        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshNow))
        refreshButton.bezelStyle = .rounded
        let exportButton = NSButton(title: "导出脱敏日志", target: self, action: #selector(exportLog))
        exportButton.bezelStyle = .rounded
        let deleteTokenButton = NSButton(title: "删除 Token", target: self, action: #selector(deleteToken))
        deleteTokenButton.bezelStyle = .rounded
        actions.addArrangedSubview(save)
        actions.addArrangedSubview(recover)
        actions.addArrangedSubview(refreshButton)
        actions.addArrangedSubview(exportButton)
        actions.addArrangedSubview(deleteTokenButton)
        stack.addArrangedSubview(actions)

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            hostField.widthAnchor.constraint(equalToConstant: 270),
            modelField.widthAnchor.constraint(equalToConstant: 270),
            tokenField.widthAnchor.constraint(equalToConstant: 270)
        ])
    }

    private func labeledField(_ title: String, field: NSTextField) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 55).isActive = true
        row.addArrangedSubview(label)
        row.addArrangedSubview(field)
        return row
    }

    @objc private func toggleAutomatic() {
        model.automaticRecoveryEnabled = automaticButton.state == .on
    }

    @objc private func assignPowerDisplay(_ sender: NSButton) {
        guard let snapshot = model.snapshots.first(where: { Int($0.displayID) == sender.tag }) else { return }
        model.useAsPowerControlled(snapshot)
        refresh()
    }

    @objc private func assignModeDisplay(_ sender: NSButton) {
        guard let snapshot = model.snapshots.first(where: { Int($0.displayID) == sender.tag }) else { return }
        model.useAsModeSwitch(snapshot)
        refresh()
    }

    @objc private func saveSettings() {
        model.appConfiguration.plug.model = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.appConfiguration.plug.host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.tokenInput = tokenField.stringValue
        model.saveConfiguration()
        tokenField.stringValue = ""
        refresh()
    }

    @objc private func triggerRecovery() {
        model.triggerRecovery()
    }

    @objc private func refreshNow() {
        Task { @MainActor in await model.refresh(); refresh() }
    }

    @objc private func exportLog() {
        guard let url = model.exportRedactedLog() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func deleteToken() {
        model.deleteToken()
        tokenField.stringValue = ""
        refresh()
    }
}
