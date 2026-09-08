import Foundation

public enum ManualAction: String, CaseIterable, Equatable, Sendable {
    case checkStatus
    case powerOff
    case powerOn
    case lowerResolution
    case restoreFullResolution
    case verifyBothScreens

    public var displayName: String {
        switch self {
        case .checkStatus:
            return "Check Status"
        case .powerOff:
            return "Turn Off"
        case .powerOn:
            return "Turn On"
        case .lowerResolution:
            return "Lower Resolution"
        case .restoreFullResolution:
            return "Restore Full Resolution"
        case .verifyBothScreens:
            return "Verify Both Screens"
        }
    }
}

public enum ManualOutcome: String, Sendable {
    case succeeded
    case failed
    case unconfirmed
    case cancelled
    case busy
}

public struct ManualActionResult: Sendable {
    public let action: ManualAction
    public let outcome: ManualOutcome
    public let shortMessage: String
    public let technicalDetails: String?

    public init(
        action: ManualAction,
        outcome: ManualOutcome,
        shortMessage: String,
        technicalDetails: String? = nil
    ) {
        self.action = action
        self.outcome = outcome
        self.shortMessage = shortMessage
        self.technicalDetails = technicalDetails
    }
}

public enum ManualActionLogEvent: Sendable {
    case started(action: ManualAction)
    case step(message: String)
    case finished(action: ManualAction, outcome: ManualOutcome, message: String, technicalDetails: String?)
}
