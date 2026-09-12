import Foundation

/// Ce qu'on manipule à l'intérieur d'une transaction.
///
/// Une transaction sert à **lire puis écrire en fonction de ce qu'on a lu**, sans qu'un
/// autre client se glisse entre les deux. Un lot ne sait pas faire ça : il écrit sans
/// jamais lire.
///
/// ```swift
/// try await store.transaction { transaction in
///     let compte = try transaction.document("c1", in: .comptes)
///     guard let compte, compte.solde >= montant else {
///         throw .transactionCancelled(reason: "solde insuffisant")
///     }
///     transaction.set(compte.débité(de: montant), id: "c1", in: .comptes)
/// }
/// ```
///
/// > **Toutes les lectures avant toutes les écritures.** Firestore l'impose, et le double
/// > en mémoire le vérifie : une lecture après une écriture jette une
/// > ``FirestoreError/invalidArgument(path:reason:)`` plutôt que de laisser découvrir la
/// > règle en production.
///
/// > **Le corps peut être rejoué.** En cas de conflit, Firestore relance la transaction
/// > depuis le début. N'y mettez donc aucun effet de bord — pas d'envoi de notification,
/// > pas d'écriture de fichier — seulement des lectures et des écritures de documents.
public protocol TransactionContext: AnyObject, Sendable {

    /// Lit un document dans la transaction.
    func document<Value: FirestoreValue>(
        at path: DocumentPath<Value>
    ) throws(FirestoreError) -> Value?

    /// Écrit un document, en remplaçant ou en fusionnant.
    func set<Value: FirestoreValue>(
        _ value: Value,
        at path: DocumentPath<Value>,
        merge: Bool
    )

    /// Met à jour des champs d'un document qui doit exister.
    func update<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        at path: DocumentPath<Value>
    )

    /// Supprime un document.
    func delete<Value: FirestoreValue>(at path: DocumentPath<Value>)
}

public extension TransactionContext {

    /// Les mêmes opérations, désignées par `id` dans une collection.
    func document<Value: FirestoreValue>(
        _ id: String,
        in collection: CollectionPath<Value>
    ) throws(FirestoreError) -> Value? {
        try document(at: collection.document(id))
    }

    func set<Value: FirestoreValue>(
        _ value: Value,
        id: String,
        in collection: CollectionPath<Value>,
        merge: Bool = false
    ) {
        set(value, at: collection.document(id), merge: merge)
    }

    func update<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        id: String,
        in collection: CollectionPath<Value>
    ) {
        update(fields, at: collection.document(id))
    }

    func delete<Value: FirestoreValue>(id: String, in collection: CollectionPath<Value>) {
        delete(at: collection.document(id))
    }
}
