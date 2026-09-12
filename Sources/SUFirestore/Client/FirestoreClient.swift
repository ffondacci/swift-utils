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
    func documents<Value: FirestoreValue>(
        _ type: Value.Type,
        in path: String,
        query: DocumentQuery,
        source: ReadSource
    ) async throws(FirestoreError) -> FirestoreQueryResult<Value>

    /// Applique un lot d'écritures de façon atomique.
    func commit(_ operations: [DocumentWrite]) async throws(FirestoreError)
}
