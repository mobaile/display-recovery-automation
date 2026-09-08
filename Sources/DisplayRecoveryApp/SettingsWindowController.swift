import AppKit
import DisplayRecoveryCore
import DisplayRecoveryMac

@MainActor
public final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private let hostField = NSTextField(string: "")
    private let keyField = NSSecureTextField(string: "")
    private let antPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let msiPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let messageLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)

    private var initialHost: String = ""
    private var initialKey: String = ""
    private var selectedAntFingerprint: DisplayFingerprint?
    private var selectedMsiFingerprint: DisplayFingerprint?

    private var onClose: (() -> Void)?

    public init(model: AppModel, onClose: (() -> Void)? = nil) {
        self.model = model
        self.onClose = onClose
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ScreenPilot Settings"
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 440, height: 320))
        window.center()
        super.init(window: window)
        window.delegate = self
        buildUI()
        loadCurrentValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    public override func showWindow(_ sender: Any?) {
        window?.makeKeyAndOrderFront(sender)
        super.showWindow(sender)
        loadCurrentValues()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func loadCurrentValues() {
        hostField.stringValue = model.appConfiguration.plug.host
        keyField.stringValue = ""
        keyField.placeholderString = model.tokenConfigured ? "(Configured - leave blank to keep unchanged)" : "(Enter 32-char hex key)"
        messageLabel.stringValue = ""

        selectedAntFingerprint = model.appConfiguration.recovery.roles.powerControlled
        selectedMsiFingerprint = model.appConfiguration.recovery.roles.modeSwitch

        updateDisplayPopUps()
    }

    private func updateDisplayPopUps() {
        antPopUp.removeAllItems()
        msiPopUp.removeAllItems()

        antPopUp.addItem(withTitle: "Select ANT display...")
        msiPopUp.addItem(withTitle: "Select MSI display...")

        let availableSnapshots = model.snapshots.filter { !$0.isBuiltin }

        for snapshot in availableSnapshots {
            let name = snapshot.fingerprint.displayName.isEmpty
                ? "Display \(snapshot.displayID)"
                : snapshot.fingerprint.displayName
            let desc = "\(name) (\(snapshot.mode?.shortDescription ?? "Unknown"))"

            antPopUp.addItem(withTitle: desc)
            msiPopUp.addItem(withTitle: desc)

            if let ant = selectedAntFingerprint, ant.matches(snapshot.fingerprint) {
                antPopUp.select(antPopUp.item(withTitle: desc))
            }
            if let msi = selectedMsiFingerprint, msi.matches(snapshot.fingerprint) {
                msiPopUp.select(msiPopUp.item(withTitle: desc))
            }
        }
    }

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        let mainStack = NSStackView()
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 14
        mainStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "Device & Network Settings")
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        mainStack.addArrangedSubview(titleLabel)

        // Network Address
        mainStack.addArrangedSubview(makeFormRow(label: "Network Address:", control: hostField))

        // Access Key + Import button
        let keyRow = NSStackView()
        keyRow.orientation = .horizontal
        keyRow.spacing = 8
        keyField.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let importBtn = NSButton(title: "Import from Keychain", target: self, action: #selector(importKeychainClicked))
        importBtn.bezelStyle = .rounded
        importBtn.controlSize = .small
        keyRow.addArrangedSubview(keyField)
        keyRow.addArrangedSubview(importBtn)
        mainStack.addArrangedSubview(makeFormRow(label: "Access Key:", control: keyRow))

        // Display Selection Section
        let displayTitle = NSTextField(labelWithString: "Display Assignment")
        displayTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        mainStack.addArrangedSubview(displayTitle)

        antPopUp.widthAnchor.constraint(equalToConstant: 260).isActive = true
        antPopUp.target = self
        antPopUp.action = #selector(antSelected)
        mainStack.addArrangedSubview(makeFormRow(label: "ANT display:", control: antPopUp))

        msiPopUp.widthAnchor.constraint(equalToConstant: 260).isActive = true
        msiPopUp.target = self
        msiPopUp.action = #selector(msiSelected)
        mainStack.addArrangedSubview(makeFormRow(label: "MSI display:", control: msiPopUp))

        // Status / Error message label
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.textColor = .systemRed
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        mainStack.addArrangedSubview(messageLabel)

        // Buttons row
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.alignment = .centerY

        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancelButton.bezelStyle = .rounded

        buttonRow.addArrangedSubview(saveButton)
        buttonRow.addArrangedSubview(cancelButton)
        mainStack.addArrangedSubview(buttonRow)

        contentView.addSubview(mainStack)
        NSLayoutConstraint.activate([
            mainStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            contentView.topAnchor.constraint(equalTo: mainStack.topAnchor, constant: 20),
            mainStack.bottomAnchor.constraint(greaterThanOrEqualTo: contentView.bottomAnchor, constant: 20),
            hostField.widthAnchor.constraint(equalToConstant: 260)
        ])
    }

    private func makeFormRow(label: String, control: NSView) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .firstBaseline

        let labelField = NSTextField(labelWithString: label)
        labelField.alignment = .right
        labelField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(control)
        return row
    }

    @objc private func antSelected() {
        let index = antPopUp.indexOfSelectedItem - 1
        let snapshots = model.snapshots.filter { !$0.isBuiltin }
        if index >= 0 && index < snapshots.count {
            selectedAntFingerprint = snapshots[index].fingerprint
        }
    }

    @objc private func msiSelected() {
        let index = msiPopUp.indexOfSelectedItem - 1
        let snapshots = model.snapshots.filter { !$0.isBuiltin }
        if index >= 0 && index < snapshots.count {
            selectedMsiFingerprint = snapshots[index].fingerprint
        }
    }

    @objc private func importKeychainClicked() {
        model.importLegacyKeychainToken()
        if model.tokenConfigured {
            messageLabel.textColor = .systemGreen
            messageLabel.stringValue = "Access key imported from Keychain."
            keyField.stringValue = ""
            keyField.placeholderString = "(Imported from Keychain)"
        } else {
            messageLabel.textColor = .systemRed
            messageLabel.stringValue = model.lastError ?? "No legacy key found in Keychain."
        }
    }

    @objc private func saveClicked() {
        saveButton.isEnabled = false
        messageLabel.stringValue = ""

        let host = hostField.stringValue
        let key = keyField.stringValue

        model.saveSettings(
            host: host,
            token: key,
            powerFingerprint: selectedAntFingerprint,
            modeFingerprint: selectedMsiFingerprint
        ) { [weak self] success in
            guard let self else { return }
            self.saveButton.isEnabled = true
            if success {
                self.window?.close()
            } else {
                self.messageLabel.textColor = .systemRed
                self.messageLabel.stringValue = self.model.lastError ?? "Failed to save settings."
                // 保存失败保留输入草稿，不清除输入内容
            }
        }
    }

    @objc private func cancelClicked() {
        window?.close()
    }
}
