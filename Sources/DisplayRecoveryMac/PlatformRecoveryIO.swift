import Foundation
import CryptoKit
import DisplayRecoveryCore
import MsiHid
import MiotLocal

public final class PlatformRecoveryIO: RecoveryIO, Sendable {
    private let displayProvider: MacDisplayProvider
    private let hidController: MsiHidController
    private let plugClient: MiotLocalClient?
    private let configuration: RecoveryConfiguration
    private let plugModel: String
    public let targetIdentity: String

    public func validateTarget(deadline: RecoveryDeadline) async throws {
        try deadline.check("Verifying configuration target")
        let saved = try ConfigurationStore().load()
        let token = SecretsStore().readToken() ?? ""
        let identity = Self.identity(plug: saved.plug, token: token)
        guard saved.recovery.roles == configuration.roles, identity == targetIdentity else {
            throw RecoveryError.operationFailed("Configuration changed; please retry with the latest settings.")
        }
        try deadline.check("Verifying configuration target")
    }

    public init(
        displayProvider: MacDisplayProvider,
        hidController: MsiHidController,
        plugConfiguration: PlugConfiguration,
        recoveryConfiguration: RecoveryConfiguration,
        token: String?,
        logStore: RecoveryLogStore = RecoveryLogStore()
    ) {
        self.displayProvider = displayProvider
        self.hidController = hidController
        self.configuration = recoveryConfiguration
        self.plugModel = plugConfiguration.model
        let normalized = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        targetIdentity = Self.identity(plug: plugConfiguration, token: normalized)
        self.plugClient = try? MiotLocalClient(host: plugConfiguration.host, token: normalized, port: plugConfiguration.port)
    }

    public func observeDisplays(deadline: RecoveryDeadline) async throws -> DisplayObservation {
        try deadline.check("Display enumeration")
        return try await MainActor.run {
            try deadline.check("Display enumeration")
            let snapshots = try displayProvider.checkedSnapshots()
            try deadline.check("Display enumeration")
            return DisplayObservation(snapshots: snapshots, observedAt: deadline.clock.monotonicNow)
        }
    }

    public func readPlugPower(deadline: RecoveryDeadline = RecoveryDeadline(seconds: 5)) async throws -> Bool {
        let client = try checkedPlug()
        _ = try await client.validate(expectedModel: plugModel, deadline: deadline)
        return try await client.getPower(deadline: deadline)
    }

    public func setPlugPower(_ on: Bool, deadline: RecoveryDeadline) async throws {
        try deadline.check("Plug power command")
        try await checkedPlug().setPower(on, expectedModel: plugModel, deadline: deadline)
    }

    public func readHardwareMode(deadline: RecoveryDeadline) async throws -> HardwareModeObservation {
        let status = try await hidController.readStatus(deadline: deadline)
        try deadline.check("MSI hardware mode readback")
        if status.isAmbiguous { throw RecoveryError.ambiguousDisplay("MSI HID") }
        guard status.connected, let identity = status.identity else { throw RecoveryError.monitorUnavailable }
        return HardwareModeObservation(mode: status.mode, identity: identity, observedAt: status.observedAt)
    }

    public func setHardwareMode(_ mode: MsiHardwareDualMode, expectedIdentity: String, deadline: RecoveryDeadline) async throws {
        let observation = try await observeDisplays(deadline: deadline)
        let resolution = DisplayRoleResolver.resolve(role: .modeSwitch, rolesConfig: configuration.roles, snapshots: observation.snapshots)
        switch resolution {
        case .ambiguous, .unconfigured: throw RecoveryError.ambiguousDisplay("MSI target")
        case .notFound where mode == .fhd: throw RecoveryError.monitorUnavailable
        default: break
        }
        try deadline.check("MSI hardware mode command")
        try await hidController.setMode(mode, expectedIdentity: expectedIdentity, deadline: deadline)
    }

    private func checkedPlug() throws -> MiotLocalClient {
        guard let plugClient else { throw RecoveryError.plugNotConfigured }
        guard MiotLocalClient.supportedModels.contains(plugModel) else {
            throw RecoveryError.plugModelMismatch(expected: plugModel, actual: "unsupported model")
        }
        return plugClient
    }

    private static func identity(plug: PlugConfiguration, token: String) -> String {
        let data = Data("\(plug.model)|\(plug.host)|\(plug.port)|\(token)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
