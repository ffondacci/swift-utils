import Foundation

/// Ce qui parle réellement à Firestore.
///
/// C'est le seul endroit du module qui connaîtrait `FirebaseFirestore` — et il ne le
/// connaît même pas : l'adaptateur vit dans `SUFirestoreLive`, derrière le trait
/// `Firebase`. Le store, lui, ne voit que ce protocole, ce qui rend le double en mémoire
/// aussi légitime que le vrai SDK.
///
/// Les chemins circulent en `String` : à ce niveau, le typage a déjà fait son travail.
public protocol FirestoreClient: Sendable {

    /// Le document, ou `nil` s'il n'existe pas.
    ///
    /// Un document absent n'est **pas** une erreur — c'est une réponse.
    func document<Value: FirestoreValue>(
        _ type: Value.Type,
        at path: String,
        source: ReadSource
    ) async throws(FirestoreError) -> FirestoreDocument<Value>?

    /// Écrit un document, en le remplaçant ou en fusionnant.
    func setDocument<Value: FirestoreValue>(
        _ value: Value,
        at path: String,
        merge: Bool
    ) async throws(FirestoreError)

    /// Met à jour des champs d'un document existant.
    ///
    /// - Throws: ``FirestoreError/notFound(path:)`` si le document n'existe pas — à la
    ///   différence de ``setDocument(_:at:merge:)``, qui le crée.
    func updateDocument(
        _ fields: [String: DocumentField],
        at path: String
    ) async throws(FirestoreError)

    /// Supprime un document. Supprimer un document absent n'est pas une erreur.
    func deleteDocument(at path: String) async throws(FirestoreError)

    /// Les documents d'une collection qui satisfont la requête, dans l'ordre demandé.
    ///
    /// > `@concurrent` : ce travail part sur l'executor global au lieu d'hériter de
    /// > l'isolation de l'appelant. Sans ça, `NonisolatedNonsendingByDefault` le ferait
    /// > tourner sur le main actor quand un store `@MainActor` l'appelle — mesuré, pas
    /// > supposé. Le volume ici est arbitraire, donc le saut d'executor est rentable.
    /// > Les opérations sur une valeur unique, elles, restent héritées : le saut y
    /// > coûterait plus cher que le travail.
    @concurrent
    func documents<Value: FirestoreValue>(
        _ type: Value.Type,
        in path: String,
        query: DocumentQuery,
        source: ReadSource
    ) async throws(FirestoreError) -> FirestoreQueryResult<Value>

    /// Applique un lot d'écritures de façon atomique.
    ///
    /// `@concurrent` : un lot peut porter jusqu'à 500 encodages.
    @concurrent
    func commit(_ operations: [DocumentWrite]) async throws(FirestoreError)

    /// Exécute une transaction : lire, décider, écrire, sans qu'un autre client
    /// s'intercale.
    ///
    /// Le corps peut être **rejoué** en cas de conflit — n'y mettez aucun effet de bord.
    ///
    /// Le corps peut jeter **n'importe quelle** erreur pour abandonner : une erreur qui
    /// n'est pas une ``FirestoreError`` devient une
    /// ``FirestoreError/transactionCancelled(reason:)``. C'est ce qui permet d'exprimer un
    /// refus métier — « solde insuffisant » — sans emprunter un cas qui ne lui correspond
    /// pas.
    func runTransaction(
        _ body: @Sendable @escaping (any TransactionContext) throws -> Void
    ) async throws(FirestoreError)
}
