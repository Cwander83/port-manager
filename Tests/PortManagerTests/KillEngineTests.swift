import XCTest
import Darwin
@testable import Core

final class KillEngineTests: XCTestCase {

    // MARK: - Default kill rule

    func testDefaultRuleReturnsKillActionForOwnedPID() async throws {
        let identity = ownIdentity
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: identity))
        let item = makeItem(port: 3000, pid: 12345, processName: "node", kind: .other)

        let action = try await rule.makeAction(item)

        XCTAssertEqual(action, .killPid(pid: 12345, processStartTime: identity.startTime, commandDescription: "kill 12345"))
    }

    func testDefaultRuleRejectsZeroPID() async {
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
        let item = makeItem(port: 3000, pid: 0, processName: "node", kind: .other)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidPID(pid: 0)))
            }
        )
    }

    func testDefaultRuleRejectsNegativePID() async {
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
        let item = makeItem(port: 3000, pid: -1, processName: "node", kind: .other)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidPID(pid: -1)))
            }
        )
    }

    func testDefaultRuleRejectsForeignPID() async {
        let identity = ProcessIdentity(uid: 0, startTime: Date(timeIntervalSince1970: 1))
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: identity))
        let item = makeItem(port: 3000, pid: 1, processName: "launchd", kind: .other)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .foreignProcess(pid: 1, ownerUID: 0)))
            }
        )
    }

    func testDefaultRuleRejectsUnknownOwner() async {
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: nil))
        let item = makeItem(port: 3000, pid: 99999, processName: "node", kind: .other)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .unknownOwner(pid: 99999)))
            }
        )
    }

    func testDefaultRuleDetectsPidReuseFromScanSnapshot() async {
        let scanStartTime = Date(timeIntervalSince1970: 1)
        let currentStartTime = Date(timeIntervalSince1970: 2)
        let identity = ProcessIdentity(uid: getuid(), startTime: currentStartTime)
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: identity))
        let item = makeItem(
            port: 3000,
            pid: 12345,
            processName: "node",
            kind: .other,
            processStartTime: scanStartTime
        )

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .processIdentityChanged(pid: 12345)))
            }
        )
    }

    func testDefaultRuleAcceptsSubSecondStartTimeDifference() async throws {
        let scanStartTime = Date(timeIntervalSince1970: 1_700_000_000)
        let currentStartTime = Date(timeIntervalSince1970: 1_700_000_000.5)
        let identity = ProcessIdentity(uid: getuid(), startTime: currentStartTime)
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: identity))
        let item = makeItem(
            port: 3000,
            pid: 12345,
            processName: "node",
            kind: .other,
            processStartTime: scanStartTime
        )

        let action = try await rule.makeAction(item)

        XCTAssertEqual(action, .killPid(pid: 12345, processStartTime: identity.startTime, commandDescription: "kill 12345"))
    }

    func testSameStartTreatsSubSecondDifferenceAsMatch() {
        let a = Date(timeIntervalSince1970: 1_700_000_000)
        let b = Date(timeIntervalSince1970: 1_700_000_000.5)
        XCTAssertTrue(sameStart(a, b))
        let c = Date(timeIntervalSince1970: 1_700_000_001)
        XCTAssertFalse(sameStart(a, c))
    }

    func testDefaultRuleSkipsPidReuseCheckWhenSnapshotNil() async throws {
        let identity = ownIdentity
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: identity))
        let item = makeItem(port: 3000, pid: 12345, processName: "node", kind: .other, processStartTime: nil)

        let action = try await rule.makeAction(item)

        if case .killPid(let pid, _, _) = action {
            XCTAssertEqual(pid, 12345)
        } else {
            XCTFail("expected killPid")
        }
    }

    // MARK: - Docker kill rule

    func testDockerRuleDispatchesStop() async throws {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "a1b2c3d4e5f6\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "0.0.0.0")

        let action = try await rule.makeAction(item)

        XCTAssertEqual(
            action,
            .dockerStop(
                containerID: "a1b2c3d4e5f6",
                commandDescription: "docker stop a1b2c3d4e5f6",
                executable: dockerPath
            )
        )
        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.arguments, ["ps", "--format", "{{.ID}}\t{{.Ports}}"])
    }

    func testDockerRuleUsesFallbackPath() async throws {
        let fallbackPath = makeTempFile(name: "docker-fallback")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "b1b2c3d4e5f6\t[::]:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: "/nonexistent/docker",
            fallbackPath: fallbackPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "[::]")

        let action = try await rule.makeAction(item)

        if case .dockerStop(_, _, let executable) = action {
            XCTAssertEqual(executable, fallbackPath)
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleMatchesPortRange() async throws {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "c1b2c3d4e5f6\t0.0.0.0:8000-8010->8000-8010/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8005, pid: 34567, processName: "docker", kind: .docker, localAddress: "0.0.0.0")

        let action = try await rule.makeAction(item)

        if case .dockerStop(let containerID, _, _) = action {
            XCTAssertEqual(containerID, "c1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleAddressNormalizationWildcardToZero() async throws {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "a1b2c3d4e5f6\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "*")

        let action = try await rule.makeAction(item)

        if case .dockerStop(let containerID, _, _) = action {
            XCTAssertEqual(containerID, "a1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleAddressNormalizationIPv6Forms() async throws {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "b1b2c3d4e5f6\t:::8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "[::]")

        let action = try await rule.makeAction(item)

        if case .dockerStop(let containerID, _, _) = action {
            XCTAssertEqual(containerID, "b1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleThrowsOnAmbiguousMatch() async {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "a1b2c3d4e5f6\t0.0.0.0:8080->8080/tcp\nb1b2c3d4e5f6\t[::]:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(
                    error as? KillEngineError,
                    .validationFailure(reason: .ambiguousContainerMatch(port: 8080))
                )
            }
        )
    }

    func testDockerRuleRejectsInvalidContainerIDLength() async {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "a1b2c3d4e5f\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID("a1b2c3d4e5f")))
            }
        )
    }

    func testDockerRuleRejectsTooLongContainerID() async {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        let tooLong = String(repeating: "a", count: 65)
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "\(tooLong)\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID(tooLong)))
            }
        )
    }

    func testDockerRuleRejectsUppercaseContainerID() async {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "A1B2C3D4E5F6\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID("A1B2C3D4E5F6")))
            }
        )
    }

    func testDockerRuleThrowsWhenBinaryMissing() async {
        let runner = MockCommandRunner()
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: "/nonexistent/docker",
            fallbackPath: "/also-missing/docker"
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .dockerBinaryMissing)
            }
        )
    }

    func testDockerRuleThrowsWhenDaemonUnavailable() async {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 1,
                stdout: "",
                stderr: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?\nmore noise"
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                guard case .dockerDaemonUnavailable(let message) = error as? KillEngineError else {
                    XCTFail("expected dockerDaemonUnavailable, got \(error)")
                    return
                }
                XCTAssertTrue(message.contains("Docker daemon"))
                XCTAssertFalse(message.contains("more noise"))
            }
        )
    }

    func testDockerRuleThrowsWhenProcessNoLongerDocker() async {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "a1b2c3d4e5f6\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "node"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .dockerProcessMismatch(pid: 34567)))
            }
        )
    }

    func testDockerRuleAcceptsDockerProxyProcess() async throws {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "a1b2c3d4e5f6\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(identity: ownIdentity, processName: "docker-proxy"),
            identityProvider: MockProcessValidator(identity: ownIdentity),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker-proxy", kind: .docker, localAddress: "0.0.0.0")

        let action = try await rule.makeAction(item)

        if case .dockerStop(let containerID, _, _) = action {
            XCTAssertEqual(containerID, "a1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleRejectsForeignOwnedProxy() async {
        let identity = ProcessIdentity(uid: 0, startTime: Date(timeIntervalSince1970: 1))
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(identity: identity, processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: identity, processName: "com.docker.backend"),
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .foreignProcess(pid: 34567, ownerUID: 0)))
            }
        )
        XCTAssertTrue(runner.invocations.isEmpty, "should not invoke docker ps for foreign proxy")
    }

    func testDockerRuleDetectsPidReuseBeforeDockerPs() async {
        let scanStartTime = Date(timeIntervalSince1970: 1)
        let currentStartTime = Date(timeIntervalSince1970: 2)
        let identity = ProcessIdentity(uid: getuid(), startTime: currentStartTime)
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            identityProvider: MockProcessValidator(identity: identity),
            primaryPath: dockerPath
        )
        let item = makeItem(
            port: 8080,
            pid: 34567,
            processName: "docker",
            kind: .docker,
            processStartTime: scanStartTime
        )

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .processIdentityChanged(pid: 34567)))
            }
        )
        XCTAssertTrue(runner.invocations.isEmpty, "should not invoke docker ps after pid-reuse detection")
    }

    // MARK: - Brew kill rule

    func testBrewRuleResolvesByPID() async throws {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "Name          Status  User  File\npostgresql@15 started chris /Users/chris/Library/LaunchAgents/homebrew.mxcl.postgresql@15.plist\nredis         started chris /Users/chris/Library/LaunchAgents/homebrew.mxcl.redis.plist",
                stderr: ""
            ),
            CommandResult(
                exitCode: 0,
                stdout: "PID\tStatus\tLabel\n23456\t0\thomebrew.mxcl.postgresql@15\n12345\t0\thomebrew.mxcl.redis",
                stderr: ""
            )
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        let action = try await rule.makeAction(item)

        XCTAssertEqual(
            action,
            .brewStop(
                serviceName: "postgresql@15",
                commandDescription: "brew services stop postgresql@15",
                executable: brewPath
            )
        )
        XCTAssertEqual(runner.invocations[1].executable, "/bin/launchctl")
        XCTAssertEqual(runner.invocations[1].arguments, ["list"])
    }

    func testBrewRuleResolvesByPrefixWithVersion() async throws {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "Name          Status  User  File\npostgresql@15 started chris /Users/chris/Library/LaunchAgents/homebrew.mxcl.postgresql@15.plist",
                stderr: ""
            ),
            CommandResult(
                exitCode: 0,
                stdout: "PID\tStatus\tLabel\n",
                stderr: ""
            )
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        let action = try await rule.makeAction(item)

        if case .brewStop(let serviceName, _, _) = action {
            XCTAssertEqual(serviceName, "postgresql@15")
        } else {
            XCTFail("expected brew stop, got \(action)")
        }
    }

    func testBrewRuleResolvesMongoDB() async throws {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "Name          Status  User  File\nmongodb-community started chris /Users/chris/Library/LaunchAgents/homebrew.mxcl.mongodb-community.plist",
                stderr: ""
            ),
            CommandResult(
                exitCode: 0,
                stdout: "PID\tStatus\tLabel\n",
                stderr: ""
            )
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 27017, pid: 77777, processName: "mongod", kind: .brew)

        let action = try await rule.makeAction(item)

        if case .brewStop(let serviceName, _, _) = action {
            XCTAssertEqual(serviceName, "mongodb-community")
        } else {
            XCTFail("expected brew stop, got \(action)")
        }
    }

    func testBrewRuleThrowsWhenBinaryMissing() async {
        let runner = MockCommandRunner()
        let rule = BrewServiceRule(
            runner: runner,
            primaryPath: "/nonexistent/brew",
            fallbackPath: "/also-missing/brew"
        )
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .brewBinaryMissing)
            }
        )
    }

    func testBrewRuleThrowsWhenListFails() async {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(exitCode: 1, stdout: "", stderr: "brew services list failed")
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .commandListUnavailable)
            }
        )
    }

    func testBrewRuleThrowsForUnmappedProcess() async {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(exitCode: 0, stdout: "Name\n", stderr: ""),
            CommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n", stderr: "")
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 9042, pid: 11111, processName: "cassandra", kind: .brew)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(
                    error as? KillEngineError,
                    .validationFailure(reason: .unmappedBrewProcess(processName: "cassandra"))
                )
            }
        )
    }

    func testBrewRuleThrowsAmbiguousPrefix() async {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "Name          Status\npostgresql@14 started\npostgresql@16 started\n",
                stderr: ""
            ),
            CommandResult(
                exitCode: 0,
                stdout: "PID\tStatus\tLabel\n",
                stderr: ""
            )
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .ambiguousBrewService))
            }
        )
    }

    func testBrewRuleResolvesTruncatedRedisServerName() async throws {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "Name          Status\nredis         started\n",
                stderr: ""
            ),
            CommandResult(
                exitCode: 0,
                stdout: "PID\tStatus\tLabel\n",
                stderr: ""
            )
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 6379, pid: 12345, processName: "redis-ser", kind: .brew)

        let action = try await rule.makeAction(item)

        if case .brewStop(let serviceName, _, _) = action {
            XCTAssertEqual(serviceName, "redis")
        } else {
            XCTFail("expected brew stop, got \(action)")
        }
    }

    // MARK: - Ollama unload rule

    func testOllamaRuleDispatchesUnload() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"llama3:70b\"}]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "llama3:70b loaded"
        )

        let action = try await rule.makeAction(item)

        let expectedURL = URL(string: "http://127.0.0.1:11434/api/generate")!
        XCTAssertEqual(
            action,
            .ollamaUnload(
                model: "llama3:70b",
                commandDescription: "unload llama3:70b (keep_alive=0)",
                url: expectedURL,
                method: "POST"
            )
        )
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/ps")
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
    }

    func testOllamaRuleSelectsMatchingModelFromMultiple() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"llama3:8b\"},{\"name\":\"mistral:latest\"}]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "mistral:latest loaded"
        )

        let action = try await rule.makeAction(item)

        if case .ollamaUnload(let model, let commandDescription, _, _) = action {
            XCTAssertEqual(model, "mistral:latest")
            XCTAssertEqual(commandDescription, "unload mistral:latest (keep_alive=0)")
        } else {
            XCTFail("expected ollama unload, got \(action)")
        }
    }

    func testOllamaRuleUsesTokenBoundaryMatch() async throws {
        // `llama3` is a substring of `llama3:70b`; only the loaded name should match.
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"llama3\"},{\"name\":\"llama3:70b\"}]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "llama3:70b loaded"
        )

        let action = try await rule.makeAction(item)

        if case .ollamaUnload(let model, _, _, _) = action {
            XCTAssertEqual(model, "llama3:70b")
        } else {
            XCTFail("expected ollama unload, got \(action)")
        }
    }

    func testOllamaRuleThrowsWhenMultipleModelsMatch() async {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"llama3:8b\"},{\"name\":\"llama3:70b\"}]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "llama3:8b and llama3:70b loaded"
        )

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .ambiguousModel))
            }
        )
    }

    func testOllamaRuleThrowsWhenAPINon200() async {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "", statusCode: 500)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(port: 11434, pid: 56789, processName: "ollama", kind: .ollama)

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .ollamaUnreachable)
            }
        )
    }

    func testOllamaRuleThrowsWhenNoModelLoaded() async {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "no model"
        )

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(
                    error as? KillEngineError,
                    .validationFailure(reason: .ollamaModelNotLoaded(port: 11434))
                )
            }
        )
    }

    func testOllamaRuleThrowsWhenModelsDoNotMatch() async {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"mistral:latest\"},{\"name\":\"codellama\"}]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "llama3:70b loaded"
        )

        await XCTAssertThrowsErrorAsync(
            { _ = try await rule.makeAction(item) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .modelNotResolvable))
            }
        )
    }

    func testOllamaRuleFallsBackToSingleLoadedModel() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"llama3:70b\"}]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "ollama"
        )

        let action = try await rule.makeAction(item)

        if case .ollamaUnload(let model, _, _, _) = action {
            XCTAssertEqual(model, "llama3:70b")
        } else {
            XCTFail("expected ollama unload, got \(action)")
        }
    }

    // MARK: - Command runner

    func testRealCommandRunnerRejectsRelativePath() async {
        let runner = RealCommandRunner()
        await XCTAssertThrowsErrorAsync(
            { _ = try await runner.run(executable: "docker", arguments: []) },
            { error in
                XCTAssertEqual(error as? CommandRunnerError, .relativePath("docker"))
            }
        )
    }

    func testRealCommandRunnerRunsAbsoluteExecutable() async throws {
        let runner = RealCommandRunner()
        let result = try await runner.run(executable: "/bin/echo", arguments: ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testRealCommandRunnerTimesOut() async {
        let runner = RealCommandRunner()
        await XCTAssertThrowsErrorAsync(
            { _ = try await runner.run(executable: "/bin/sleep", arguments: ["10"], timeout: 0.1) },
            { error in
                XCTAssertEqual(error as? CommandRunnerError, .timeout)
            }
        )
    }

    func testMockCommandRunnerRecordsInvocationsAndClearsNextError() async throws {
        let runner = MockCommandRunner()
        runner.nextError = CommandRunnerError.timeout
        await XCTAssertThrowsErrorAsync(
            { _ = try await runner.run(executable: "/bin/x", arguments: []) },
            { _ in }
        )
        XCTAssertNil(runner.nextError)
        runner.results = [CommandResult(exitCode: 0, stdout: "out", stderr: "err")]

        let result = try await runner.run(executable: "/bin/x", arguments: ["a", "b"])

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(runner.invocations[1].executable, "/bin/x")
        XCTAssertEqual(runner.invocations[1].arguments, ["a", "b"])
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    // MARK: - KillEngine dispatch

    func testEngineDispatchesDockerRule() async throws {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "a1b2c3d4e5f6\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let engine = KillEngine(
            runner: runner,
            rules: [
                DockerKillRule(
                    runner: runner,
                    nameProvider: MockProcessValidator(processName: "com.docker.backend"),
                    identityProvider: MockProcessValidator(identity: ownIdentity),
                    primaryPath: dockerPath
                ),
                DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
            ]
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "0.0.0.0")

        let action = try await engine.action(for: item)

        if case .dockerStop(let containerID, let commandDescription, _) = action {
            XCTAssertEqual(containerID, "a1b2c3d4e5f6")
            XCTAssertEqual(commandDescription, "docker stop a1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testEngineDispatchesBrewRule() async throws {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "Name          Status\npostgresql@16 started\n",
                stderr: ""
            ),
            CommandResult(
                exitCode: 0,
                stdout: "PID\tStatus\tLabel\n23456\t0\thomebrew.mxcl.postgresql@16",
                stderr: ""
            )
        ]
        let engine = KillEngine(
            runner: runner,
            rules: [
                BrewServiceRule(runner: runner, primaryPath: brewPath),
                DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
            ]
        )
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        let action = try await engine.action(for: item)

        if case .brewStop(let serviceName, let commandDescription, _) = action {
            XCTAssertEqual(serviceName, "postgresql@16")
            XCTAssertEqual(commandDescription, "brew services stop postgresql@16")
        } else {
            XCTFail("expected brew stop, got \(action)")
        }
    }

    func testEngineDispatchesOllamaRule() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"llama3:70b\"}]}", statusCode: 200)
        ]
        let engine = KillEngine(
            httpTransport: transport,
            rules: [
                OllamaUnloadRule(transport: transport),
                DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
            ]
        )
        let item = makeItem(
            port: 11434,
            pid: 56789,
            processName: "ollama",
            kind: .ollama,
            label: "ollama",
            subtitle: "llama3:70b loaded"
        )

        let action = try await engine.action(for: item)

        if case .ollamaUnload(let model, let commandDescription, _, _) = action {
            XCTAssertEqual(model, "llama3:70b")
            XCTAssertEqual(commandDescription, "unload llama3:70b (keep_alive=0)")
        } else {
            XCTFail("expected ollama unload, got \(action)")
        }
    }

    func testEngineFallsBackToDefaultKillForBrewNamedOtherItem() async throws {
        let engine = KillEngine(
            runner: MockCommandRunner(),
            rules: [
                BrewServiceRule(runner: MockCommandRunner()),
                DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
            ]
        )
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .other)

        let action = try await engine.action(for: item)

        if case .killPid(let pid, _, _) = action {
            XCTAssertEqual(pid, 23456)
        } else {
            XCTFail("expected killPid, got \(action)")
        }
    }

    // MARK: - Execute

    func testExecuteKillPidTerminatesProcessWithSIGTERM() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let pid = process.processIdentifier
        defer {
            if process.isRunning {
                kill(pid, SIGKILL)
                process.waitUntilExit()
            }
        }
        let startTime = await waitForProcessStart(pid: pid)
        XCTAssertNotNil(startTime)

        let engine = KillEngine(identityProvider: ProcessOwnerValidator())
        try await engine.execute(
            .killPid(pid: pid, processStartTime: startTime, commandDescription: "kill \(pid)"),
            using: MockCommandRunner()
        )

        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGTERM)
    }

    func testExecuteKillPidEscalatesToSIGKILL() async throws {
        let readyPath = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: readyPath) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "trap '' TERM; touch \(readyPath); while true; do sleep 1; done"]
        try process.run()
        let pid = process.processIdentifier
        defer {
            if process.isRunning {
                kill(pid, SIGKILL)
                process.waitUntilExit()
            }
        }
        let startTime = await waitForProcessStart(pid: pid)
        XCTAssertNotNil(startTime)
        await waitForFile(at: readyPath)

        let engine = KillEngine(identityProvider: ProcessOwnerValidator())
        try await engine.execute(
            .killPid(pid: pid, processStartTime: startTime, commandDescription: "kill \(pid)"),
            using: MockCommandRunner(),
            escalate: true
        )

        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(process.terminationStatus, SIGKILL)
    }

    func testExecuteRejectsKillingSelf() async {
        let engine = KillEngine(identityProvider: ProcessOwnerValidator())
        let pid = getpid()

        await XCTAssertThrowsErrorAsync(
            {
                try await engine.execute(
                    .killPid(pid: pid, processStartTime: nil, commandDescription: "kill \(pid)"),
                    using: MockCommandRunner()
                )
            },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .cannotSignalSelf(pid: pid)))
            }
        )
    }

    func testExecuteRejectsPidReuse() async {
        let capturedStartTime = Date(timeIntervalSince1970: 1)
        let currentStartTime = Date(timeIntervalSince1970: 2)
        let identity = ProcessIdentity(uid: getuid(), startTime: currentStartTime)
        let engine = KillEngine(identityProvider: MockProcessValidator(identity: identity))
        let pid: pid_t = 33320

        await XCTAssertThrowsErrorAsync(
            {
                try await engine.execute(
                    .killPid(pid: pid, processStartTime: capturedStartTime, commandDescription: "kill \(pid)"),
                    using: MockCommandRunner()
                )
            },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .processIdentityChanged(pid: pid)))
            }
        )
    }

    func testExecuteDockerStopUsesRunnerAndRevalidatesID() async throws {
        let runner = MockCommandRunner()
        runner.results = [CommandResult(exitCode: 0, stdout: "", stderr: "")]
        let engine = KillEngine()
        let action = KillAction.dockerStop(
            containerID: "a1b2c3d4e5f6",
            commandDescription: "docker stop a1b2c3d4e5f6",
            executable: "/tmp/docker"
        )

        try await engine.execute(action, using: runner)

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.executable, "/tmp/docker")
        XCTAssertEqual(runner.invocations.first?.arguments, ["stop", "a1b2c3d4e5f6"])
    }

    func testExecuteDockerStopThrowsOnInvalidID() async {
        let runner = MockCommandRunner()
        let engine = KillEngine()
        let action = KillAction.dockerStop(
            containerID: "short",
            commandDescription: "docker stop short",
            executable: "/tmp/docker"
        )

        await XCTAssertThrowsErrorAsync(
            { try await engine.execute(action, using: runner) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID("short")))
            }
        )
    }

    func testExecuteDockerStopThrowsOnFailure() async {
        let runner = MockCommandRunner()
        runner.results = [CommandResult(exitCode: 1, stdout: "", stderr: "docker failed")]
        let engine = KillEngine()
        let action = KillAction.dockerStop(
            containerID: "a1b2c3d4e5f6",
            commandDescription: "docker stop a1b2c3d4e5f6",
            executable: "/tmp/docker"
        )

        await XCTAssertThrowsErrorAsync(
            { try await engine.execute(action, using: runner) },
            { error in
                XCTAssertTrue(error is KillExecutionError)
            }
        )
    }

    func testExecuteBrewStopRejectsInvalidServiceName() async {
        let runner = MockCommandRunner()
        let engine = KillEngine()
        let action = KillAction.brewStop(
            serviceName: "-evil",
            commandDescription: "brew services stop -evil",
            executable: "/tmp/brew"
        )

        await XCTAssertThrowsErrorAsync(
            { try await engine.execute(action, using: runner) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidServiceName("-evil")))
            }
        )
    }

    func testExecuteOllamaUnloadUsesHTTPTransport() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{}", statusCode: 200)
        ]
        let engine = KillEngine(httpTransport: transport)
        let url = URL(string: "http://127.0.0.1:11434/api/generate")!
        let action = KillAction.ollamaUnload(
            model: "llama3:70b",
            commandDescription: "unload llama3:70b (keep_alive=0)",
            url: url,
            method: "POST"
        )

        try await engine.execute(action, using: MockCommandRunner())

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.httpMethod, "POST")
        XCTAssertEqual(transport.requests.first?.url, url)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = transport.requests.first?.httpBody ?? Data()
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "llama3:70b")
        XCTAssertEqual(json?["keep_alive"] as? Int, 0)
    }

    func testExecuteOllamaUnloadRejectsUnsafeURL() async {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{}", statusCode: 200)
        ]
        let engine = KillEngine(httpTransport: transport)
        let url = URL(string: "http://example.com:11434/api/generate")!
        let action = KillAction.ollamaUnload(
            model: "llama3:70b",
            commandDescription: "unload llama3:70b (keep_alive=0)",
            url: url,
            method: "POST"
        )

        await XCTAssertThrowsErrorAsync(
            { try await engine.execute(action, using: MockCommandRunner()) },
            { error in
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidOllamaURL))
                XCTAssertEqual(transport.requests.count, 0)
            }
        )
    }

    func testExecuteOllamaUnloadThrowsOnHTTPError() async {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "Internal Server Error", statusCode: 500)
        ]
        let engine = KillEngine(httpTransport: transport)
        let url = URL(string: "http://127.0.0.1:11434/api/generate")!
        let action = KillAction.ollamaUnload(
            model: "llama3:70b",
            commandDescription: "unload llama3:70b (keep_alive=0)",
            url: url,
            method: "POST"
        )

        await XCTAssertThrowsErrorAsync(
            { try await engine.execute(action, using: MockCommandRunner()) },
            { error in
                XCTAssertTrue(error is KillExecutionError)
            }
        )
    }

    // MARK: - Main-actor compile proof

    @MainActor
    func testExecuteCompilesFromMainActor() async throws {
        let engine = KillEngine(identityProvider: ProcessOwnerValidator())
        let runner = MockCommandRunner()
        runner.results = [CommandResult(exitCode: 0, stdout: "", stderr: "")]
        // This test only needs to compile and run trivially; real kill tests are above.
        let action = KillAction.dockerStop(
            containerID: "a1b2c3d4e5f6",
            commandDescription: "docker stop a1b2c3d4e5f6",
            executable: "/tmp/docker"
        )
        try await engine.execute(action, using: runner)
    }

    // MARK: - LocalizedError

    func testDockerDaemonErrorMessageIsActionable() {
        let error = KillEngineError.dockerDaemonUnavailable(message: "docker daemon down")
        XCTAssertEqual(error.localizedDescription, "Docker daemon is unavailable — stop the container via Docker Desktop. docker daemon down")
    }

    func testValidationErrorDoesNotLeakFullOutput() {
        let error = KillEngineError.validationFailure(reason: .containerLookupFailed(port: 8080))
        let message = error.localizedDescription
        XCTAssertTrue(message.contains("Could not find"))
        XCTAssertFalse(message.contains("docker ps"))
    }

    func testCommandRunnerErrorLocalizedDescription() {
        XCTAssertEqual(CommandRunnerError.relativePath("docker").localizedDescription, "Executable path must be absolute: docker.")
        XCTAssertEqual(CommandRunnerError.timeout.localizedDescription, "Command timed out.")
    }

    func testHTTPTransportErrorLocalizedDescription() {
        XCTAssertEqual(HTTPTransportError.timeout.localizedDescription, "HTTP request timed out.")
        XCTAssertEqual(HTTPTransportError.noResponse.localizedDescription, "HTTP request returned no response.")
    }

    func testInvalidOllamaURLErrorMessage() {
        let error = KillEngineError.validationFailure(reason: .invalidOllamaURL)
        XCTAssertTrue(error.localizedDescription.contains("localhost"))
    }

    func testSelfKillErrorMessage() {
        let error = KillEngineError.validationFailure(reason: .cannotSignalSelf(pid: getpid()))
        XCTAssertTrue(error.localizedDescription.contains("Cannot signal the running application"))
    }
}

// MARK: - Helpers

private func makeItem(
    port: Int,
    pid: pid_t,
    processName: String,
    kind: ListenerKind,
    label: String = "",
    subtitle: String = "",
    localAddress: String? = nil,
    processStartTime: Date? = nil
) -> PortItem {
    PortItem(
        port: port,
        pid: pid,
        processName: processName,
        kind: kind,
        label: label,
        subtitle: subtitle,
        ramBytes: nil,
        isZombie: false,
        processStartTime: processStartTime,
        localAddress: localAddress
    )
}

private func waitForFile(at path: String, timeoutNanoseconds: UInt64 = 5_000_000_000, intervalNanoseconds: UInt64 = 10_000_000) async {
    let iterations = Int(timeoutNanoseconds / intervalNanoseconds)
    for _ in 0..<iterations {
        if FileManager.default.fileExists(atPath: path) { return }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    XCTFail("ready file did not appear at \(path)")
}

private func waitForProcessStart(pid: pid_t, timeoutNanoseconds: UInt64 = 5_000_000_000, intervalNanoseconds: UInt64 = 10_000_000) async -> Date? {
    let iterations = Int(timeoutNanoseconds / intervalNanoseconds)
    for _ in 0..<iterations {
        if let start = ProcessOwnerValidator().identity(of: pid)?.startTime {
            return start
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return nil
}

private var ownIdentity: ProcessIdentity {
    ProcessIdentity(uid: getuid(), startTime: Date(timeIntervalSince1970: Date().timeIntervalSince1970))
}

private func makeTempFile(name: String) -> String {
    let directory = FileManager.default.temporaryDirectory
    let path = directory.appendingPathComponent("\(UUID().uuidString)-\(name)").path
    FileManager.default.createFile(atPath: path, contents: Data(), attributes: nil)
    return path
}

private func makeHTTPResponse(body: String, statusCode: Int) -> (Data, URLResponse) {
    let data = body.data(using: .utf8) ?? Data()
    let url = URL(string: "http://127.0.0.1:11434")!
    let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: nil
    )!
    return (data, response)
}

private struct MockProcessValidator: ProcessIdentityProvider, ProcessNameProvider, Sendable {
    let identity: ProcessIdentity?
    let processName: String?

    init(identity: ProcessIdentity? = nil, processName: String? = nil) {
        self.identity = identity
        self.processName = processName
    }

    func identity(of pid: pid_t) -> ProcessIdentity? {
        identity
    }

    func processName(of pid: pid_t) -> String? {
        processName
    }
}

private final class MockHTTPTransport: HTTPTransport, @unchecked Sendable {
    var requests: [URLRequest] = []
    var responses: [(Data, URLResponse)] = []

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw HTTPTransportError.noResponse
        }
        return responses.removeFirst()
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
