import Foundation

struct OllamaUnloadRule: KillRule {
    private let transport: HTTPTransport

    init(transport: HTTPTransport = RealHTTPTransport()) {
        self.transport = transport
    }

    func canHandle(_ item: PortItem) -> Bool {
        item.kind == .ollama || (item.port == 11434 && item.processName == "ollama")
    }

    func makeAction(_ item: PortItem) throws -> KillAction {
        let models = try loadedModels()
        guard let model = models.first else {
            throw KillEngineError.validationFailure(reason: .ollamaModelNotLoaded(port: item.port))
        }

        let url = URL(string: "http://127.0.0.1:11434/api/unload")!
        let body = try JSONSerialization.data(withJSONObject: ["model": model])

        return .ollamaUnload(
            model: model,
            commandDescription: "unload \(model) via Ollama API",
            url: url,
            method: "DELETE",
            body: body
        )
    }

    private func loadedModels() throws -> [String] {
        let url = URL(string: "http://127.0.0.1:11434/api/ps")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return []
        }
        return parseModels(from: data)
    }
}

private func parseModels(from data: Data) -> [String] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return []
    }
    guard let models = json["models"] as? [[String: Any]] else {
        return []
    }
    return models.compactMap { $0["name"] as? String }
}
