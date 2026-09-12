import Foundation

/// Ce qui gouverne une requête au-delà de son contenu : combien de temps on attend, et
/// combien de fois on réessaie.
///
/// Le client porte une politique par défaut ; un endpoint peut la remplacer via
/// ``Endpoint/policy``.
public struct RequestPolicy: Sendable, Equatable {

    public var timeout: Duration
    public var retry: RetryPolicy

    public init(timeout: Duration = .seconds(30), retry: RetryPolicy = .default) {
        self.timeout = timeout
        self.retry = retry
    }

    public static let `default` = RequestPolicy()
}

/// Quand et comment réessayer.
public struct RetryPolicy: Sendable, Equatable {

    /// Nombre de tentatives **supplémentaires**. `0` signifie « un seul essai ».
    public var maxRetries: Int

    /// Les statuts qui méritent une nouvelle tentative.
    public var retryableStatusCodes: Set<Int>

    /// L'attente entre deux tentatives.
    public var backoff: Backoff

    /// Si le serveur envoie `Retry-After`, on le respecte plutôt que d'appliquer le
    /// backoff. Il sait mieux que nous quand il sera prêt.
    public var respectsRetryAfter: Bool

    /// Ne rejouer que les verbes idempotents. Réémettre un `POST` après un timeout peut
    /// créer deux commandes — le serveur l'a peut-être reçu avant de ne pas répondre.
    public var idempotentMethodsOnly: Bool

    public init(
        maxRetries: Int = 2,
        retryableStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504],
        backoff: Backoff = .exponential(base: .seconds(1), jitter: true),
        respectsRetryAfter: Bool = true,
        idempotentMethodsOnly: Bool = true
    ) {
        self.maxRetries = maxRetries
        self.retryableStatusCodes = retryableStatusCodes
        self.backoff = backoff
        self.respectsRetryAfter = respectsRetryAfter
        self.idempotentMethodsOnly = idempotentMethodsOnly
    }

    public static let `default` = RetryPolicy()

    /// Une seule tentative, jamais de reprise.
    public static let none = RetryPolicy(maxRetries: 0)
}

/// L'attente entre deux tentatives.
public enum Backoff: Sendable, Equatable {

    /// Toujours la même attente.
    case constant(Duration)

    /// L'attente double à chaque tentative.
    ///
    /// - Parameter jitter: ajoute un aléa jusqu'à 50 %. Sans lui, mille clients tombés en
    ///   même temps reviennent tous en même temps, et achèvent le serveur qui se
    ///   relevait.
    case exponential(base: Duration, jitter: Bool)

    /// - Parameter attempt: la tentative à venir, à partir de 1.
    public func delay(forAttempt attempt: Int) -> Duration {
        switch self {
        case let .constant(duration):
            return duration

        case let .exponential(base, jitter):
            let multiplier = pow(2.0, Double(max(0, attempt - 1)))
            let seconds = Double(base.components.seconds) * multiplier
            let noise = jitter ? Double.random(in: 0...(seconds * 0.5)) : 0
            return .seconds(seconds + noise)
        }
    }
}
