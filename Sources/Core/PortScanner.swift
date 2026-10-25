import Foundation

/// Contract for port-scanning implementations.
///
/// Security and execution rules for real scanners:
/// - Spawn processes using absolute paths only (e.g. `/usr/sbin/lsof`,
///   `/opt/homebrew/bin/docker` or `/usr/local/bin/docker`).
/// - Pass commands as `argv` arrays; never invoke `/bin/sh -c` or other shells.
/// - Do not rely on `PATH` lookup for privileged or destructive binaries.
/// - Validate `pid_t > 0` and confirm process ownership before calling `kill(2)`.
/// - Validate container IDs against `^[0-9a-f]{12,64}$` before passing to Docker.
/// - Prefer direct `kill(2)` over `killall`/`pkill` to avoid accidental broad matches.
public protocol PortScanner: Sendable {
    func scan() async throws -> [PortItem]
}
