import Foundation

/// Le transport réel, adossé à `URLSession`.
public struct URLSessionTransport: Transport {

    private let session: URLSession

    /// - Parameter session: la session à utiliser. Par défaut une session éphémère sans
    ///   cache : la mise en cache est une décision de politique, pas un effet de bord du
    ///   transport.
    public init(session: URLSession = .makeDefault()) {
        self.session = session
    }

    public func execute(_ request: TransportRequest) async throws(NetworkError) -> TransportResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = Double(request.timeout.components.seconds)

        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let body = request.body {
            urlRequest.httpBody = body.data
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch {
            throw .transportFailed(
                context: NetworkErrorContext(
                    method: request.method.rawValue,
                    url: request.url.absoluteString,
                    requestHeaders: request.headers
                ),
                reason: error.localizedDescription
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw .transportFailed(
                context: NetworkErrorContext(
                    method: request.method.rawValue,
                    url: request.url.absoluteString,
                    requestHeaders: request.headers
                ),
                reason: "réponse non HTTP"
            )
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }

        return TransportResponse(data: data, statusCode: http.statusCode, headers: headers)
    }
}

public extension URLSession {
    /// Une session éphémère, sans cache disque ni cookies persistants.
    ///
    /// Le transport ne met rien en cache de lui-même : ce qui doit être caché relève
    /// d'une politique explicite, décidée au-dessus, pas d'un comportement par défaut
    /// d'`URLSession` qu'on découvre en production.
    static func makeDefault() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
