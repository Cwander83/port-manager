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
        let model = try selectModel(for: item, from: models)

        let url = URL(string: "http://127.0.0.1:11434/api/generate")!
        let body = try JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": 0])

        return .ollamaUnload(
            model: model,
            commandDescription: "unload \(model) (keep_alive=0)",
            url: url,
            method: "POST",
            body: body
        )
    }

    private func loadedModels() throws -> [String] {
        let url = URL(string: "http://127.0.0.1:11434/api/ps")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw KillEngineError.ollamaUnreachable
        }
        return parseModels(from: data)
    }

    private func selectModel(for item: PortItem, from models: [String]) throws -> String {
        let haystack = "\(item.label) \(item.subtitle)".lowercased()
        let matches = models.filter { haystack.contains($0.lowercased()) }

        if matches.count == 1 {
            return matches[0]
        }
        if matches.count > 1 {
            throw KillEngineError.validationFailure(reason: .ambiguousModel)
        }
        if models.isEmpty {
            throw KillEngineError.validationFailure(reason: .ollamaModelNotLoaded(port: item.port))
        }
        throw KillEngineError.validationFailure(reason: .ollamaModelNotLoaded(port: item.port))
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
