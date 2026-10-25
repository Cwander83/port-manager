import XCTest
import Darwin
@testable import Core

final class KillEngineTests: XCTestCase {

    // MARK: - Default kill rule

    func testDefaultRuleReturnsKillActionForOwnedPID() throws {
        let identity = ownIdentity
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: identity))
        let item = makeItem(port: 3000, pid: 12345, processName: "node", kind: .other)

        let action = try rule.makeAction(item)

        XCTAssertEqual(action, .killPid(pid: 12345, processStartTime: identity.startTime, commandDescription: "kill 12345"))
    }

    func testDefaultRuleRejectsZeroPID() {
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
        let item = makeItem(port: 3000, pid: 0, processName: "node", kind: .other)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidPID(pid: 0)))
        }
    }

    func testDefaultRuleRejectsNegativePID() {
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
        let item = makeItem(port: 3000, pid: -1, processName: "node", kind: .other)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidPID(pid: -1)))
        }
    }

    func testDefaultRuleRejectsForeignPID() {
        let identity = ProcessIdentity(uid: 0, startTime: Date(timeIntervalSince1970: 1))
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: identity))
        let item = makeItem(port: 3000, pid: 1, processName: "launchd", kind: .other)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .foreignProcess(pid: 1, ownerUID: 0)))
        }
    }

    func testDefaultRuleRejectsUnknownOwner() {
        let rule = DefaultKillRule(identityProvider: MockProcessValidator(identity: nil))
        let item = makeItem(port: 3000, pid: 99999, processName: "node", kind: .other)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .unknownOwner(pid: 99999)))
        }
    }

    // MARK: - Docker kill rule

    func testDockerRuleDispatchesStop() throws {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "0.0.0.0")

        let action = try rule.makeAction(item)

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

    func testDockerRuleUsesFallbackPath() throws {
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
            primaryPath: "/nonexistent/docker",
            fallbackPath: fallbackPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "[::]")

        let action = try rule.makeAction(item)

        if case .dockerStop(_, _, let executable) = action {
            XCTAssertEqual(executable, fallbackPath)
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleMatchesPortRange() throws {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8005, pid: 34567, processName: "docker", kind: .docker, localAddress: "0.0.0.0")

        let action = try rule.makeAction(item)

        if case .dockerStop(let containerID, _, _) = action {
            XCTAssertEqual(containerID, "c1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleThrowsOnAmbiguousMatch() {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(
                error as? KillEngineError,
                .validationFailure(reason: .ambiguousContainerMatch(port: 8080))
            )
        }
    }

    func testDockerRuleRejectsInvalidContainerIDLength() {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID("a1b2c3d4e5f")))
        }
    }

    func testDockerRuleRejectsTooLongContainerID() {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID(tooLong)))
        }
    }

    func testDockerRuleRejectsUppercaseContainerID() {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID("A1B2C3D4E5F6")))
        }
    }

    func testDockerRuleThrowsWhenBinaryMissing() {
        let runner = MockCommandRunner()
        let rule = DockerKillRule(
            runner: runner,
            nameProvider: MockProcessValidator(processName: "com.docker.backend"),
            primaryPath: "/nonexistent/docker",
            fallbackPath: "/also-missing/docker"
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .dockerBinaryMissing)
        }
    }

    func testDockerRuleThrowsWhenDaemonUnavailable() {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            guard case .dockerDaemonUnavailable(let message) = error as? KillEngineError else {
                XCTFail("expected dockerDaemonUnavailable, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("Docker daemon"))
            XCTAssertFalse(message.contains("more noise"))
        }
    }

    func testDockerRuleThrowsWhenProcessNoLongerDocker() {
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
            primaryPath: dockerPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .dockerProcessMismatch(pid: 34567)))
        }
    }

    // MARK: - Brew kill rule

    func testBrewRuleResolvesByPID() throws {
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

        let action = try rule.makeAction(item)

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

    func testBrewRuleResolvesByPrefixWithVersion() throws {
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

        let action = try rule.makeAction(item)

        if case .brewStop(let serviceName, _, _) = action {
            XCTAssertEqual(serviceName, "postgresql@15")
        } else {
            XCTFail("expected brew stop, got \(action)")
        }
    }

    func testBrewRuleResolvesMongoDB() throws {
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

        let action = try rule.makeAction(item)

        if case .brewStop(let serviceName, _, _) = action {
            XCTAssertEqual(serviceName, "mongodb-community")
        } else {
            XCTFail("expected brew stop, got \(action)")
        }
    }

    func testBrewRuleThrowsWhenBinaryMissing() {
        let runner = MockCommandRunner()
        let rule = BrewServiceRule(
            runner: runner,
            primaryPath: "/nonexistent/brew",
            fallbackPath: "/also-missing/brew"
        )
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .brewBinaryMissing)
        }
    }

    func testBrewRuleThrowsForUnmappedProcess() {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(exitCode: 0, stdout: "Name\n", stderr: ""),
            CommandResult(exitCode: 0, stdout: "PID\tStatus\tLabel\n", stderr: "")
        ]
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 9042, pid: 11111, processName: "cassandra", kind: .brew)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(
                error as? KillEngineError,
                .validationFailure(reason: .unmappedBrewProcess(processName: "cassandra"))
            )
        }
    }

    // MARK: - Ollama unload rule

    func testOllamaRuleDispatchesUnload() throws {
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

        let action = try rule.makeAction(item)

        let expectedURL = URL(string: "http://127.0.0.1:11434/api/generate")!
        let expectedBody = try JSONSerialization.data(withJSONObject: ["model": "llama3:70b", "keep_alive": 0])
        XCTAssertEqual(
            action,
            .ollamaUnload(
                model: "llama3:70b",
                commandDescription: "unload llama3:70b (keep_alive=0)",
                url: expectedURL,
                method: "POST",
                body: expectedBody
            )
        )
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/ps")
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
    }

    func testOllamaRuleSelectsMatchingModelFromMultiple() throws {
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

        let action = try rule.makeAction(item)

        if case .ollamaUnload(let model, let commandDescription, _, _, _) = action {
            XCTAssertEqual(model, "mistral:latest")
            XCTAssertEqual(commandDescription, "unload mistral:latest (keep_alive=0)")
        } else {
            XCTFail("expected ollama unload, got \(action)")
        }
    }

    func testOllamaRuleThrowsWhenMultipleModelsMatch() {
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

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .ambiguousModel))
        }
    }

    func testOllamaRuleThrowsWhenAPINon200() {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "", statusCode: 500)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(port: 11434, pid: 56789, processName: "ollama", kind: .ollama)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .ollamaUnreachable)
        }
    }

    func testOllamaRuleThrowsWhenNoModelLoaded() {
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

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(
                error as? KillEngineError,
                .validationFailure(reason: .ollamaModelNotLoaded(port: 11434))
            )
        }
    }

    // MARK: - Command runner

    func testRealCommandRunnerRejectsRelativePath() {
        let runner = RealCommandRunner(timeout: 5)
        XCTAssertThrowsError(try runner.run(executable: "docker", arguments: [])) { error in
            XCTAssertEqual(error as? CommandRunnerError, .relativePath("docker"))
        }
    }

    func testRealCommandRunnerRunsAbsoluteExecutable() throws {
        let runner = RealCommandRunner(timeout: 5)
        let result = try runner.run(executable: "/bin/echo", arguments: ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testMockCommandRunnerRecordsInvocationsAndClearsNextError() throws {
        let runner = MockCommandRunner()
        runner.nextError = CommandRunnerError.timeout
        XCTAssertThrowsError(try runner.run(executable: "/bin/x", arguments: []))
        XCTAssertNil(runner.nextError)
        runner.results = [CommandResult(exitCode: 0, stdout: "out", stderr: "err")]

        let result = try runner.run(executable: "/bin/x", arguments: ["a", "b"])

        XCTAssertEqual(runner.invocations.count, 2)
        XCTAssertEqual(runner.invocations[1].executable, "/bin/x")
        XCTAssertEqual(runner.invocations[1].arguments, ["a", "b"])
        XCTAssertEqual(result.stdout, "out")
        XCTAssertEqual(result.stderr, "err")
    }

    // MARK: - KillEngine dispatch

    func testEngineDispatchesDockerRule() throws {
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
                    primaryPath: dockerPath
                ),
                DefaultKillRule(identityProvider: MockProcessValidator(identity: ownIdentity))
            ]
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker, localAddress: "0.0.0.0")

        let action = try engine.action(for: item)

        if case .dockerStop(let containerID, let commandDescription, _) = action {
            XCTAssertEqual(containerID, "a1b2c3d4e5f6")
            XCTAssertEqual(commandDescription, "docker stop a1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testEngineDispatchesBrewRule() throws {
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

        let action = try engine.action(for: item)

        if case .brewStop(let serviceName, let commandDescription, _) = action {
            XCTAssertEqual(serviceName, "postgresql@16")
            XCTAssertEqual(commandDescription, "brew services stop postgresql@16")
        } else {
            XCTFail("expected brew stop, got \(action)")
        }
    }

    func testEngineDispatchesOllamaRule() throws {
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

        let action = try engine.action(for: item)

        if case .ollamaUnload(let model, let commandDescription, _, _, _) = action {
            XCTAssertEqual(model, "llama3:70b")
            XCTAssertEqual(commandDescription, "unload llama3:70b (keep_alive=0)")
        } else {
            XCTFail("expected ollama unload, got \(action)")
        }
    }

    // MARK: - Execute

    func testExecuteKillPidTerminatesProcessWithSIGTERM() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let pid = process.processIdentifier
        let startTime = ProcessOwnerValidator().identity(of: pid)?.startTime

        let engine = KillEngine(identityProvider: ProcessOwnerValidator())
        try await engine.execute(
            .killPid(pid: pid, processStartTime: startTime, commandDescription: "kill \(pid)"),
            using: MockCommandRunner()
        )

        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
    }

    func testExecuteKillPidEscalatesToSIGKILL() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; sleep 30"]
        try process.run()
        let pid = process.processIdentifier
        let startTime = ProcessOwnerValidator().identity(of: pid)?.startTime

        let engine = KillEngine(identityProvider: ProcessOwnerValidator())
        try await engine.execute(
            .killPid(pid: pid, processStartTime: startTime, commandDescription: "kill \(pid)"),
            using: MockCommandRunner(),
            escalate: true
        )

        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
    }

    func testExecuteRejectsKillingSelf() async throws {
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
                XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidPID(pid: pid)))
            }
        )
    }

    func testExecuteRejectsPidReuse() async throws {
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

    func testExecuteOllamaUnloadUsesHTTPTransport() async throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{}", statusCode: 200)
        ]
        let engine = KillEngine(httpTransport: transport)
        let url = URL(string: "http://127.0.0.1:11434/api/generate")!
        let body = try JSONSerialization.data(withJSONObject: ["model": "llama3:70b", "keep_alive": 0])
        let action = KillAction.ollamaUnload(
            model: "llama3:70b",
            commandDescription: "unload llama3:70b (keep_alive=0)",
            url: url,
            method: "POST",
            body: body
        )

        try await engine.execute(action, using: MockCommandRunner())

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.httpMethod, "POST")
        XCTAssertEqual(transport.requests.first?.url, url)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "Content-Type"), "application/json")
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
            method: "POST",
            body: Data()
        )

        await XCTAssertThrowsErrorAsync(
            { try await engine.execute(action, using: MockCommandRunner()) },
            { error in
                XCTAssertTrue(error is KillExecutionError)
            }
        )
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
}

// MARK: - Helpers

private func makeItem(
    port: Int,
    pid: pid_t,
    processName: String,
    kind: ListenerKind,
    label: String = "",
    subtitle: String = "",
    localAddress: String? = nil
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
        processStartTime: nil,
        localAddress: localAddress
    )
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

private struct MockProcessValidator: ProcessOwnershipValidator, ProcessIdentityProvider, ProcessNameProvider {
    var identity: ProcessIdentity?
    var processName: String?

    init(identity: ProcessIdentity? = nil, processName: String? = nil) {
        self.identity = identity
        self.processName = processName
    }

    func ownerUID(of pid: pid_t) -> uid_t? {
        identity?.uid
    }

    func isOwnedByCurrentUser(pid: pid_t) -> Bool {
        identity?.uid == getuid()
    }

    func identity(of pid: pid_t) -> ProcessIdentity? {
        identity
    }

    func processName(of pid: pid_t) -> String? {
        processName
    }
}

private final class MockHTTPTransport: HTTPTransport {
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
