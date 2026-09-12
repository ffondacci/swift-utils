import Foundation

/// Rejoue une requête qui a échoué de façon transitoire.
///
/// Deux sources de reprise : une erreur de transport — pas de réseau, timeout — et un
/// statut que la politique juge rejouable. Une erreur de décodage ou un 404, eux, ne
/// s'arrangeront jamais en réessayant.
///
/// Placez-le **après** l'authentification dans la liste : chaque tentative doit repartir
/// avec un jeton valide, pas avec celui capturé au premier essai.
public struct RetryMiddleware: Middleware {

    public init() {}

    public func intercept(
        _ context: RequestContext,
        next: @escaping MiddlewareChain
    ) async throws(NetworkError) -> TransportResponse {
        let policy = context.policy.retry

        guard policy.maxRetries > 0, isReplayable(context.request.method, policy) else {
            return try await next(context)
        }

        var attempt = 0
        while true {
            var attemptContext = context
            attemptContext.attempt = attempt

            let outcome: Result<TransportResponse, NetworkError>
            do {
                outcome = .success(try await next(attemptContext))
            } catch {
                outcome = .failure(error)
            }

            let shouldRetry: Bool
            var response: TransportResponse?

            switch outcome {
            case let .success(value):
                response = value
                shouldRetry = policy.retryableStatusCodes.contains(value.statusCode)
            case let .failure(error):
                shouldRetry = error.isRetryable
            }

            guard shouldRetry, attempt < policy.maxRetries else {
                return try outcome.get()
            }

            try await wait(policy.delay(forAttempt: attempt + 1, response: response))
            attempt += 1
        }
    }

    private func isReplayable(_ method: HTTPMethod, _ policy: RetryPolicy) -> Bool {
        policy.idempotentMethodsOnly ? method.isIdempotent : true
    }

    /// L'attente entre deux tentatives.
    ///
    /// C'est le seul `Task.sleep` du dépôt, et il ne sert pas à synchroniser quoi que ce
    /// soit : le backoff *est* le comportement voulu. L'annulation pendant l'attente
    /// remonte comme telle.
    private func wait(_ duration: Duration) async throws(NetworkError) {
        do {
            try await Task.sleep(for: duration)
        } catch {
            throw .cancelled
        }
    }
}

extension RetryPolicy {
    /// L'attente avant la prochaine tentative.
    ///
    /// Un `Retry-After` renvoyé par le serveur l'emporte sur le backoff : il sait mieux
    /// que nous quand il sera prêt à répondre.
    func delay(forAttempt attempt: Int, response: TransportResponse?) -> Duration {
        if respectsRetryAfter,
           let header = response?.header("Retry-After"),
           let seconds = Double(header.trimmingCharacters(in: .whitespaces)),
           seconds >= 0 {
            return .seconds(seconds)
        }
        return backoff.delay(forAttempt: attempt)
    }
}
