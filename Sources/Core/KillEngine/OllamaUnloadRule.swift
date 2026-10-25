import Foundation

struct OllamaUnloadRule: KillRule {
    private let transport: HTTPTransport

    init(transport: HTTPTransport = RealHTTPTransport()) {
        self.transport = transport
    }

    func canHandle(_ item: PortItem) -> Bool {
        item.kind == .ollama || (item.port == 11434 && item.processName == "ollama")
    }

    func makeAction(_ item: PortItem) async throws -> KillAction {
        let models = try loadedModels()
        let model = try selectModel(for: item, from: models)

        let url = try ollamaURL(path: "/api/generate")

        return .ollamaUnload(
            model: model,
            commandDescription: "unload \(model) (keep_alive=0)",
            url: url,
            method: "POST"
        )
    }

    private func loadedModels() throws -> [String] {
        let url = try ollamaURL(path: "/api/ps")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let (data, response) = try transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw KillEngineError.ollamaUnreachable
        }
        return parseModels(from: data)
    }

    private func selectModel(for item: PortItem, from models: [String]) throws -> String {
        if models.count == 1, let only = models.first {
            return only
        }

        let haystack = "\(item.label) \(item.subtitle)".lowercased()
        var matches = models.filter { modelName in
            matchesModel(modelName, in: haystack)
        }

        // If a longer model name matches, discard shorter names that are its
        // prefix (e.g. "llama3" is a prefix of "llama3:70b"). This keeps the
        // tagged model from being double-counted.
        matches = matches.filter { candidate in
            !matches.contains { other in
                other != candidate && other.lowercased().hasPrefix(candidate.lowercased())
            }
        }

        if matches.count == 1 {
            return matches[0]
        }
        if matches.count > 1 {
            throw KillEngineError.validationFailure(reason: .ambiguousModel)
        }
        if models.isEmpty {
            throw KillEngineError.validationFailure(reason: .ollamaModelNotLoaded(port: item.port))
        }
        throw KillEngineError.validationFailure(reason: .modelNotResolvable)
    }

    private func matchesModel(_ modelName: String, in haystack: String) -> Bool {
        let needle = modelName.lowercased()
        // Token boundary = whitespace or common punctuation (,;()).
        // Colon is part of Ollama model names, so it is NOT a boundary.
        let separators = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ",;()"))
        let tokens = haystack.lowercased().components(separatedBy: separators)
        return tokens.contains(needle)
    }
}

private func ollamaURL(path: String) throws -> URL {
    guard let url = URL(string: "http://127.0.0.1:11434\(path)") else {
        throw KillEngineError.ollamaUnreachable
    }
    return url
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
