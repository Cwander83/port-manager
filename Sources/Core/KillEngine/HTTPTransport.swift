import Foundation

/// Synchronous HTTP transport used by the Ollama rule and kill execution.
/// Real implementation bridges `URLSession` into the sync rule/execute APIs.
public protocol HTTPTransport {
    func data(for request: URLRequest) throws -> (Data, URLResponse)
}

public struct RealHTTPTransport: HTTPTransport {
    public init() {}

    public func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                box.value = .failure(error)
            } else if let data = data, let response = response {
                box.value = .success((data, response))
            } else {
                box.value = .failure(KillExecutionError.httpFailure)
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        return try box.value!.get()
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<(Data, URLResponse), Error>?
}
