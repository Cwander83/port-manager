import Foundation

struct DefaultKillRule: KillRule {
    private let validator: ProcessOwnershipValidator
    private let identityProvider: ProcessIdentityProvider

    init(
        validator: ProcessOwnershipValidator = ProcessOwnerValidator(),
        identityProvider: ProcessIdentityProvider = ProcessOwnerValidator()
    ) {
        self.validator = validator
        self.identityProvider = identityProvider
    }

    func canHandle(_ item: PortItem) -> Bool {
        true
    }

    func makeAction(_ item: PortItem) throws -> KillAction {
        guard item.pid > 0 else {
            throw KillEngineError.validationFailure(reason: .invalidPID(pid: item.pid))
        }

        guard let identity = identityProvider.identity(of: item.pid) else {
            throw KillEngineError.validationFailure(reason: .unknownOwner(pid: item.pid))
        }
        guard identity.uid == getuid() else {
            throw KillEngineError.validationFailure(reason: .foreignProcess(pid: item.pid, ownerUID: identity.uid))
        }

        return .killPid(
            pid: item.pid,
            processStartTime: identity.startTime,
            commandDescription: "kill \(item.pid)"
        )
    }
}
