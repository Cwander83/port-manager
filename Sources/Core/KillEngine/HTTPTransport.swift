import Foundation

public enum HTTPTransportError: Error, Equatable {
    case timeout
    case noResponse
}

extension HTTPTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout:
            return "HTTP request timed out."
        case .noResponse:
            return "HTTP request returned no response."
        }
    }
}

/// Synchronous HTTP transport used by the async Ollama rule and kill execution.
/// Real implementation bridges `URLSession` into the sync protocol surface.
///
/// Callers await at the rule/execute boundary; the sync `data(for:)` call blocks
/// a cooperative thread for up to the configured timeout (default 5s). Full
/// cancellation is not implemented — a timed-out request is cancelled, but the
/// blocked thread is not pre-empted.
///
/// The protocol is `Sendable`; concrete implementations are structs that create
/// a fresh `URLSession` per call and hold no shared mutable state, so they are
/// safe to capture across isolation boundaries.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) throws -> (Data, URLResponse)
}

public struct RealHTTPTransport: HTTPTransport {
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

        var task: URLSessionDataTask?
        task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                box.value = .failure(error)
            } else if let data = data, let response = response {
                box.value = .success((data, response))
            } else {
                box.value = .failure(HTTPTransportError.noResponse)
            }
            semaphore.signal()
        }
        task?.resume()

        let waitResult = semaphore.wait(timeout: .now() + timeout)

        if waitResult == .timedOut {
            task?.cancel()
            session.finishTasksAndInvalidate()
            throw HTTPTransportError.timeout
        }

        session.finishTasksAndInvalidate()

        if let value = box.value {
            return try value.get()
        }
        throw HTTPTransportError.noResponse
    }
}

/// Locked box: the callback writes once and then signals, so the only possible
/// race is a stale read after a timeout (which we throw away). Marked
/// `@unchecked Sendable` for that exact single-writer-after-cancel guarantee.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Result<(Data, URLResponse), Error>?

    var value: Result<(Data, URLResponse), Error>? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        set {
            lock.lock(); defer { lock.unlock() }
            _value = newValue
        }
    }
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
