import Foundation

/// Les catégories d'échec qu'il est sensé de rejouer.
///
/// Firestore distingue nettement « ça ne marchera jamais » de « réessaie ». Un refus des
/// règles de sécurité ou un document mal formé sont des décisions ; les quatre cas
/// ci-dessous sont des accidents de circonstance.
public enum RetryableFailure: Sendable, Hashable, CaseIterable {

    /// Le backend est injoignable — réseau coupé, service indisponible.
    case unavailable

    /// **La contention.** Plusieurs écritures ont visé le même document au même moment et
    /// Firestore en a abandonné une pour préserver la cohérence. C'est le cas où rejouer
    /// est non seulement permis mais attendu : la seconde tentative trouvera la voie
    /// libre.
    case aborted

    /// Quota ou débit dépassé. Rejouer **avec attente** laisse le temps au compteur de
    /// retomber ; rejouer immédiatement ne ferait qu'aggraver.
    case resourceExhausted

    /// L'opération a dépassé son délai.
    case deadlineExceeded
}

/// Quand et comment rejouer une opération Firestore.
///
/// > **Pourquoi les écritures sont rejouables ici, contrairement à `SUNetworking`.**
/// > Un `POST` HTTP peut créer deux commandes s'il est rejoué. Les écritures Firestore
/// > sont **absolues** — `set`, `update` et `delete` décrivent un état final, pas un
/// > incrément — donc les rejouer aboutit au même document. C'est ce qui autorise la
/// > reprise sur les écritures comme sur les lectures.
/// >
/// > La réserve tient si vous passez un jour à `FieldValue.increment`, qui est relatif.
/// > Ce module ne l'expose pas.
public struct FirestoreRetryPolicy: Sendable, Equatable {

    /// Nombre de tentatives **supplémentaires**. `0` signifie « un seul essai ».
    public var maxRetries: Int

    /// Les catégories d'échec à rejouer.
    public var retries: Set<RetryableFailure>

    /// L'attente entre deux tentatives.
    public var backoff: Backoff

    public init(
        maxRetries: Int = 3,
        retries: Set<RetryableFailure> = Set(RetryableFailure.allCases),
        backoff: Backoff = .exponential(base: .milliseconds(200), jitter: true)
    ) {
        self.maxRetries = maxRetries
        self.retries = retries
        self.backoff = backoff
    }

    public static let `default` = FirestoreRetryPolicy()

    /// Une seule tentative, jamais de reprise.
    ///
    /// > Le nom évite `none` : en position optionnelle, `.none` désigne `Optional.none` et
    /// > le compilateur le choisit **en silence**. Une politique qu'on croit désactivée
    /// > redeviendrait celle par défaut.
    public static let disabled = FirestoreRetryPolicy(maxRetries: 0)

    /// Indique si cette erreur doit être rejouée selon la politique.
    public func allowsRetry(of error: FirestoreError) -> Bool {
        guard let failure = error.retryableFailure else { return false }
        return retries.contains(failure)
    }
}

/// L'attente entre deux tentatives.
///
/// > Le type existe aussi dans `SUNetworking`. Les modules du dépôt sont indépendants par
/// > défaut — les faire dépendre l'un de l'autre pour vingt lignes coûterait plus cher que
/// > de les écrire deux fois.
public enum Backoff: Sendable, Equatable {

    /// Toujours la même attente.
    case constant(Duration)

    /// L'attente double à chaque tentative.
    ///
    /// - Parameter jitter: ajoute un aléa jusqu'à 50 %. En cas de contention, c'est ce qui
    ///   évite que les deux écritures qui se sont percutées reviennent exactement en même
    ///   temps et se percutent à nouveau.
    case exponential(base: Duration, jitter: Bool)

    /// - Parameter attempt: la tentative à venir, à partir de 1.
    public func delay(forAttempt attempt: Int) -> Duration {
        switch self {
        case let .constant(duration):
            return duration

        case let .exponential(base, jitter):
            let multiplier = pow(2.0, Double(max(0, attempt - 1)))
            let milliseconds = Double(base.components.attoseconds) / 1e15
                + Double(base.components.seconds) * 1_000
            let scaled = milliseconds * multiplier
            let noise = jitter ? Double.random(in: 0...(scaled * 0.5)) : 0
            return .milliseconds(Int(scaled + noise))
        }
    }
}

extension FirestoreError {
    /// La catégorie de reprise à laquelle cette erreur appartient, s'il y en a une.
    var retryableFailure: RetryableFailure? {
        switch self {
        case .unavailable: .unavailable
        case .aborted: .aborted
        case .resourceExhausted: .resourceExhausted
        case .deadlineExceeded: .deadlineExceeded
        case .permissionDenied, .notFound, .alreadyExists, .unauthenticated,
             .failedPrecondition, .invalidArgument, .decodingFailed,
             .encodingFailed, .cancelled, .transactionCancelled, .unknown:
            nil
        }
    }
}
