import Foundation

struct DefaultKillRule: KillRule {
    private let validator: ProcessOwnershipValidator

    init(validator: ProcessOwnershipValidator = ProcessOwnerValidator()) {
        self.validator = validator
    }

    func canHandle(_ item: PortItem) -> Bool {
        true
    }

    func makeAction(_ item: PortItem) throws -> KillAction {
        guard item.pid > 0 else {
            throw KillEngineError.validationFailure(reason: .invalidPID(pid: item.pid))
        }
        guard validator.isOwnedByCurrentUser(pid: item.pid) else {
            let owner = validator.ownerUID(of: item.pid) ?? 0
            throw KillEngineError.validationFailure(reason: .foreignProcess(pid: item.pid, ownerUID: owner))
        }
        return .killPid(pid: item.pid, commandDescription: "kill \(item.pid)")
    }
}
