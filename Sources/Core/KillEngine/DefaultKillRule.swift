import Foundation

struct DefaultKillRule: KillRule {
    private let identityProvider: ProcessIdentityProvider

    init(identityProvider: ProcessIdentityProvider = ProcessOwnerValidator()) {
        self.identityProvider = identityProvider
    }

    func canHandle(_ item: PortItem) -> Bool {
        true
    }

    func makeAction(_ item: PortItem) async throws -> KillAction {
        guard item.pid > 0 else {
            throw KillEngineError.validationFailure(reason: .invalidPID(pid: item.pid))
        }

        guard let identity = identityProvider.identity(of: item.pid) else {
            throw KillEngineError.validationFailure(reason: .unknownOwner(pid: item.pid))
        }
        guard identity.uid == getuid() else {
            throw KillEngineError.validationFailure(reason: .foreignProcess(pid: item.pid, ownerUID: identity.uid))
        }

        // If the scanner provided a process-start snapshot, verify it has not
        // changed before returning the action. A nil snapshot (e.g. from a mock
        // scanner) skips this check — documented in tests.
        if let snapshot = item.processStartTime {
            guard sameStart(identity.startTime, snapshot) else {
                throw KillEngineError.validationFailure(reason: .processIdentityChanged(pid: item.pid))
            }
        }

        return .killPid(
            pid: item.pid,
            processStartTime: identity.startTime,
            commandDescription: "kill \(item.pid)"
        )
    }
}
