import Foundation

public enum HTTPTransportError: Error, Equatable {
    case timeout
    case noResponse
    case invalidRedirect
}

/// Synchronous HTTP transport used by the Ollama rule and kill execution.
/// Real implementation bridges `URLSession` into the sync rule/execute APIs.
public protocol HTTPTransport {
    func data(for request: URLRequest) throws -> (Data, URLResponse)
}

public struct RealHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func data(for request: URLRequest) throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.connectionProxyDictionary = [:]
        // Prevent redirects from escaping localhost.
        configuration.httpShouldSetCookies = false

        let delegate = LocalHostRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                box.value = .failure(error)
            } else if let data = data, let response = response {
                box.value = .success((data, response))
            } else {
                box.value = .failure(HTTPTransportError.noResponse)
            }
            semaphore.signal()
        }
        task.resume()

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        session.finishTasksAndInvalidate()

        if waitResult == .timedOut {
            task.cancel()
            throw HTTPTransportError.timeout
        }

        if let value = box.value {
            return try value.get()
        }
        throw HTTPTransportError.noResponse
    }
}

private final class ResultBox: @unchecked Sendable {
    var value: Result<(Data, URLResponse), Error>?
}

private final class LocalHostRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host, host == "127.0.0.1" || host == "localhost" else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
