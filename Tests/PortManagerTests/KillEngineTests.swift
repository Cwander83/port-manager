import XCTest
import Darwin
@testable import Core

final class KillEngineTests: XCTestCase {

    // MARK: - Default kill rule

    func testDefaultRuleReturnsKillActionForOwnedPID() throws {
        let rule = DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
        let item = makeItem(port: 3000, pid: 12345, processName: "node", kind: .other)

        let action = try rule.makeAction(item)

        XCTAssertEqual(action, .killPid(pid: 12345, commandDescription: "kill 12345"))
    }

    func testDefaultRuleRejectsZeroPID() {
        let rule = DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
        let item = makeItem(port: 3000, pid: 0, processName: "node", kind: .other)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidPID(pid: 0)))
        }
    }

    func testDefaultRuleRejectsNegativePID() {
        let rule = DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
        let item = makeItem(port: 3000, pid: -1, processName: "node", kind: .other)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidPID(pid: -1)))
        }
    }

    func testDefaultRuleRejectsForeignPID() {
        let rule = DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: false, ownerUID: 0))
        let item = makeItem(port: 3000, pid: 1, processName: "launchd", kind: .other)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .foreignProcess(pid: 1, ownerUID: 0)))
        }
    }

    func testRealProcessOwnershipValidatorRecognizesOwnProcess() {
        let validator = ProcessOwnerValidator()
        XCTAssertTrue(validator.isOwnedByCurrentUser(pid: getpid()))
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
        let rule = DockerKillRule(runner: runner, primaryPath: dockerPath)
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        let action = try rule.makeAction(item)

        XCTAssertEqual(
            action,
            .dockerStop(
                containerID: "a1b2c3d4e5f6",
                commandDescription: "docker stop a1b2c3d4e5f6",
                executable: dockerPath,
                arguments: ["stop", "a1b2c3d4e5f6"]
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
                stdout: "b1b2c3d4e5f6\t:::8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(
            runner: runner,
            primaryPath: "/nonexistent/docker",
            fallbackPath: fallbackPath
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        let action = try rule.makeAction(item)

        if case .dockerStop(_, _, let executable, _) = action {
            XCTAssertEqual(executable, fallbackPath)
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testDockerRuleRejectsInvalidContainerID() {
        let dockerPath = makeTempFile(name: "docker")
        let runner = MockCommandRunner()
        runner.results = [
            CommandResult(
                exitCode: 0,
                stdout: "short\t0.0.0.0:8080->8080/tcp",
                stderr: ""
            )
        ]
        let rule = DockerKillRule(runner: runner, primaryPath: dockerPath)
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .validationFailure(reason: .invalidContainerID("short")))
        }
    }

    func testDockerRuleThrowsWhenBinaryMissing() {
        let runner = MockCommandRunner()
        let rule = DockerKillRule(
            runner: runner,
            primaryPath: "/nonexistent/docker",
            fallbackPath: "/also-missing/docker"
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(error as? KillEngineError, .dockerBinaryMissing)
        }
    }

    // MARK: - Brew kill rule

    func testBrewRuleDispatchesStopForPostgres() throws {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        let action = try rule.makeAction(item)

        XCTAssertEqual(
            action,
            .brewStop(
                serviceName: "postgresql@16",
                commandDescription: "brew services stop postgresql@16",
                executable: brewPath,
                arguments: ["services", "stop", "postgresql@16"]
            )
        )
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
        let rule = BrewServiceRule(runner: runner, primaryPath: brewPath)
        let item = makeItem(port: 9042, pid: 11111, processName: "cassandra", kind: .brew)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(
                error as? KillEngineError,
                .validationFailure(reason: .unmappedBrewProcess(processName: "cassandra"))
            )
        }
    }

    func testBrewNameMappingTable() {
        XCTAssertEqual(BrewServiceNameMapping.table["postgres"], "postgresql@16")
        XCTAssertEqual(BrewServiceNameMapping.table["redis-server"], "redis")
        XCTAssertEqual(BrewServiceNameMapping.table["mysqld"], "mysql")
    }

    // MARK: - Ollama unload rule

    func testOllamaRuleDispatchesUnload() throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[{\"name\":\"llama3:70b\"}]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(port: 11434, pid: 56789, processName: "ollama", kind: .ollama)

        let action = try rule.makeAction(item)

        let expectedURL = URL(string: "http://127.0.0.1:11434/api/unload")!
        let expectedBody = try JSONSerialization.data(withJSONObject: ["model": "llama3:70b"])
        XCTAssertEqual(
            action,
            .ollamaUnload(
                model: "llama3:70b",
                commandDescription: "unload llama3:70b via Ollama API",
                url: expectedURL,
                method: "DELETE",
                body: expectedBody
            )
        )
        XCTAssertEqual(transport.requests.first?.url?.path, "/api/ps")
        XCTAssertEqual(transport.requests.first?.httpMethod, "GET")
    }

    func testOllamaRuleThrowsWhenNoModelLoaded() {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{\"models\":[]}", statusCode: 200)
        ]
        let rule = OllamaUnloadRule(transport: transport)
        let item = makeItem(port: 11434, pid: 56789, processName: "ollama", kind: .ollama)

        XCTAssertThrowsError(try rule.makeAction(item)) { error in
            XCTAssertEqual(
                error as? KillEngineError,
                .validationFailure(reason: .ollamaModelNotLoaded(port: 11434))
            )
        }
    }

    // MARK: - Command runner

    func testRealCommandRunnerRejectsRelativePath() {
        let runner = RealCommandRunner()
        XCTAssertThrowsError(try runner.run(executable: "docker", arguments: [])) { error in
            XCTAssertEqual(error as? CommandRunnerError, .relativePath("docker"))
        }
    }

    func testRealCommandRunnerRunsAbsoluteExecutable() throws {
        let runner = RealCommandRunner()
        let result = try runner.run(executable: "/bin/echo", arguments: ["hello"])
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    func testMockCommandRunnerRecordsInvocations() throws {
        let runner = MockCommandRunner()
        runner.results = [CommandResult(exitCode: 0, stdout: "out", stderr: "err")]

        let result = try runner.run(executable: "/bin/x", arguments: ["a", "b"])

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.executable, "/bin/x")
        XCTAssertEqual(runner.invocations.first?.arguments, ["a", "b"])
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
                DockerKillRule(runner: runner, primaryPath: dockerPath),
                DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
            ]
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        let action = try engine.action(for: item)

        if case .dockerStop(let containerID, let commandDescription, _, _) = action {
            XCTAssertEqual(containerID, "a1b2c3d4e5f6")
            XCTAssertEqual(commandDescription, "docker stop a1b2c3d4e5f6")
        } else {
            XCTFail("expected docker stop, got \(action)")
        }
    }

    func testEngineDispatchesBrewRule() throws {
        let brewPath = makeTempFile(name: "brew")
        let runner = MockCommandRunner()
        let engine = KillEngine(
            runner: runner,
            rules: [
                BrewServiceRule(runner: runner, primaryPath: brewPath),
                DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
            ]
        )
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        let action = try engine.action(for: item)

        if case .brewStop(let serviceName, let commandDescription, _, _) = action {
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
                DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
            ]
        )
        let item = makeItem(port: 11434, pid: 56789, processName: "ollama", kind: .ollama)

        let action = try engine.action(for: item)

        if case .ollamaUnload(let model, let commandDescription, _, _, _) = action {
            XCTAssertEqual(model, "llama3:70b")
            XCTAssertEqual(commandDescription, "unload llama3:70b via Ollama API")
        } else {
            XCTFail("expected ollama unload, got \(action)")
        }
    }

    func testEngineFallsBackToKillWhenDockerBinaryMissing() throws {
        let runner = MockCommandRunner()
        let engine = KillEngine(
            runner: runner,
            rules: [
                DockerKillRule(
                    runner: runner,
                    primaryPath: "/nonexistent/docker",
                    fallbackPath: "/also-missing/docker"
                ),
                DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
            ]
        )
        let item = makeItem(port: 8080, pid: 34567, processName: "docker", kind: .docker)

        let action = try engine.action(for: item)

        if case .killPid(let pid, let commandDescription) = action {
            XCTAssertEqual(pid, 34567)
            XCTAssertEqual(
                commandDescription,
                "kill 34567 (Docker CLI unavailable; stopping proxy process as fallback)"
            )
        } else {
            XCTFail("expected kill fallback, got \(action)")
        }
    }

    func testEngineFallsBackToKillWhenBrewBinaryMissing() throws {
        let runner = MockCommandRunner()
        let engine = KillEngine(
            runner: runner,
            rules: [
                BrewServiceRule(
                    runner: runner,
                    primaryPath: "/nonexistent/brew",
                    fallbackPath: "/also-missing/brew"
                ),
                DefaultKillRule(validator: MockProcessOwnershipValidator(isOwned: true))
            ]
        )
        let item = makeItem(port: 5432, pid: 23456, processName: "postgres", kind: .brew)

        let action = try engine.action(for: item)

        if case .killPid(let pid, let commandDescription) = action {
            XCTAssertEqual(pid, 23456)
            XCTAssertEqual(
                commandDescription,
                "kill 23456 (Homebrew unavailable; stopping proxy process as fallback)"
            )
        } else {
            XCTFail("expected kill fallback, got \(action)")
        }
    }

    // MARK: - Execute

    func testExecuteKillPidTerminatesProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["10"]
        try process.run()
        let pid = process.processIdentifier

        let engine = KillEngine()
        try engine.execute(.killPid(pid: pid, commandDescription: "kill \(pid)"), runner: RealCommandRunner())

        process.waitUntilExit()
        XCTAssertNotEqual(process.terminationStatus, 0)
    }

    func testExecuteDockerStopUsesRunner() throws {
        let runner = MockCommandRunner()
        runner.results = [CommandResult(exitCode: 0, stdout: "", stderr: "")]
        let engine = KillEngine()
        let action = KillAction.dockerStop(
            containerID: "a1b2c3d4e5f6",
            commandDescription: "docker stop a1b2c3d4e5f6",
            executable: "/tmp/docker",
            arguments: ["stop", "a1b2c3d4e5f6"]
        )

        try engine.execute(action, runner: runner)

        XCTAssertEqual(runner.invocations.count, 1)
        XCTAssertEqual(runner.invocations.first?.executable, "/tmp/docker")
        XCTAssertEqual(runner.invocations.first?.arguments, ["stop", "a1b2c3d4e5f6"])
    }

    func testExecuteDockerStopThrowsOnFailure() {
        let runner = MockCommandRunner()
        runner.results = [CommandResult(exitCode: 1, stdout: "", stderr: "docker failed")]
        let engine = KillEngine()
        let action = KillAction.dockerStop(
            containerID: "a1b2c3d4e5f6",
            commandDescription: "docker stop a1b2c3d4e5f6",
            executable: "/tmp/docker",
            arguments: ["stop", "a1b2c3d4e5f6"]
        )

        XCTAssertThrowsError(try engine.execute(action, runner: runner)) { error in
            XCTAssertTrue(error is KillExecutionError)
        }
    }

    func testExecuteOllamaUnloadUsesHTTPTransport() throws {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "{}", statusCode: 200)
        ]
        let engine = KillEngine(httpTransport: transport)
        let url = URL(string: "http://127.0.0.1:11434/api/unload")!
        let body = try JSONSerialization.data(withJSONObject: ["model": "llama3:70b"])
        let action = KillAction.ollamaUnload(
            model: "llama3:70b",
            commandDescription: "unload llama3:70b via Ollama API",
            url: url,
            method: "DELETE",
            body: body
        )

        try engine.execute(action, runner: MockCommandRunner())

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(transport.requests.first?.url, url)
    }

    func testExecuteOllamaUnloadThrowsOnHTTPError() {
        let transport = MockHTTPTransport()
        transport.responses = [
            makeHTTPResponse(body: "Internal Server Error", statusCode: 500)
        ]
        let engine = KillEngine(httpTransport: transport)
        let url = URL(string: "http://127.0.0.1:11434/api/unload")!
        let action = KillAction.ollamaUnload(
            model: "llama3:70b",
            commandDescription: "unload llama3:70b via Ollama API",
            url: url,
            method: "DELETE",
            body: Data()
        )

        XCTAssertThrowsError(try engine.execute(action, runner: MockCommandRunner())) { error in
            XCTAssertTrue(error is KillExecutionError)
        }
    }
}

// MARK: - Helpers

private func makeItem(
    port: Int,
    pid: pid_t,
    processName: String,
    kind: ListenerKind
) -> PortItem {
    PortItem(
        port: port,
        pid: pid,
        processName: processName,
        kind: kind,
        label: "",
        subtitle: "",
        ramBytes: nil,
        isZombie: false
    )
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

private struct MockProcessOwnershipValidator: ProcessOwnershipValidator {
    var isOwned: Bool
    var ownerUID: uid_t

    init(isOwned: Bool, ownerUID: uid_t = 0) {
        self.isOwned = isOwned
        self.ownerUID = ownerUID
    }

    func ownerUID(of pid: pid_t) -> uid_t? {
        ownerUID
    }

    func isOwnedByCurrentUser(pid: pid_t) -> Bool {
        isOwned
    }
}

private final class MockHTTPTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Data, URLResponse)] = []

    func data(for request: URLRequest) throws -> (Data, URLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        return responses.removeFirst()
    }
}
