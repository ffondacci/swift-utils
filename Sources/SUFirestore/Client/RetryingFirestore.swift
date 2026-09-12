import Foundation

/// Rejoue les opérations qui ont échoué de façon transitoire.
///
/// C'est un client qui en enveloppe un autre — le même motif que les middlewares de
/// `SUNetworking`, réduit à sa plus simple expression. Il se compose avec n'importe quel
/// ``FirestoreClient``, le vrai comme le double de test :
///
/// ```swift
/// let store = FirestoreStore(
///     client: RetryingFirestore(wrapping: LiveFirestore(), policy: .default)
/// )
/// ```
///
/// Le cas qu'il traite le mieux est **la contention** : deux appareils qui écrivent le
/// même document au même instant. Firestore en abandonne un avec `aborted`, et la seconde
/// tentative trouve la voie libre. Sans reprise, l'app aurait affiché une erreur pour un
/// incident qui se résout tout seul en 200 ms.
public struct RetryingFirestore: FirestoreClient {

    private let wrapped: any FirestoreClient
    private let policy: FirestoreRetryPolicy

    public init(wrapping client: any FirestoreClient, policy: FirestoreRetryPolicy = .default) {
        self.wrapped = client
        self.policy = policy
    }

    // MARK: - Lecture

    public func document<Value: FirestoreValue>(
        _ type: Value.Type,
        at path: String,
        source: ReadSource
    ) async throws(FirestoreError) -> FirestoreDocument<Value>? {
        try await retrying { () async throws(FirestoreError) -> FirestoreDocument<Value>? in
            try await wrapped.document(type, at: path, source: source)
        }
    }

    public func documents<Value: FirestoreValue>(
        _ type: Value.Type,
        in path: String,
        query: DocumentQuery,
        source: ReadSource
    ) async throws(FirestoreError) -> FirestoreQueryResult<Value> {
        try await retrying { () async throws(FirestoreError) -> FirestoreQueryResult<Value> in
            try await wrapped.documents(type, in: path, query: query, source: source)
        }
    }

    // MARK: - Écriture

    public func setDocument<Value: FirestoreValue>(
        _ value: Value,
        at path: String,
        merge: Bool
    ) async throws(FirestoreError) {
        try await retrying { () async throws(FirestoreError) in
            try await wrapped.setDocument(value, at: path, merge: merge)
        }
    }

    public func updateDocument(
        _ fields: [String: DocumentField],
        at path: String
    ) async throws(FirestoreError) {
        // Un incrément est relatif : le rejouer après un timeout douteux compterait deux
        // fois, puisque le serveur l'a peut-être appliqué avant de ne pas répondre.
        guard fields.values.allSatisfy({ !$0.isRelative }) else {
            return try await wrapped.updateDocument(fields, at: path)
        }
        try await retrying { () async throws(FirestoreError) in
            try await wrapped.updateDocument(fields, at: path)
        }
    }

    public func deleteDocument(at path: String) async throws(FirestoreError) {
        try await retrying { () async throws(FirestoreError) in
            try await wrapped.deleteDocument(at: path)
        }
    }

    public func commit(_ operations: [DocumentWrite]) async throws(FirestoreError) {
        // Un seul incrément dans le lot suffit à le rendre non rejouable.
        guard operations.allSatisfy(\.isIdempotent) else {
            return try await wrapped.commit(operations)
        }
        try await retrying { () async throws(FirestoreError) in
            try await wrapped.commit(operations)
        }
    }

    // MARK: - Reprise

    private func retrying<T>(
        _ operation: () async throws(FirestoreError) -> T
    ) async throws(FirestoreError) -> T {
        var attempt = 0

        while true {
            do {
                return try await operation()
            } catch {
                guard policy.allowsRetry(of: error), attempt < policy.maxRetries else {
                    throw error
                }
                attempt += 1
                do {
                    // L'attente *est* le comportement voulu : sans elle, rejouer une
                    // contention la reproduit à l'identique.
                    try await Task.sleep(for: policy.backoff.delay(forAttempt: attempt))
                } catch {
                    throw FirestoreError.cancelled
                }
            }
        }
    }
}
