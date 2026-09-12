import Foundation

/// Une écriture à appliquer dans un lot.
public enum DocumentWrite: @unchecked Sendable {
    // `any FirestoreValue` est `Sendable` par contrainte, mais le compilateur ne peut pas
    // le prouver à travers l'existentiel. La valeur est immuable et n'est lue qu'une fois,
    // au moment de la validation du lot.
    case set(path: String, value: any FirestoreValue, merge: Bool)
    case update(path: String, fields: [String: DocumentField])
    case delete(path: String)

    public var path: String {
        switch self {
        case let .set(path, _, _), let .update(path, _), let .delete(path): path
        }
    }

    /// Indique si rejouer cette écriture aboutit au même document.
    ///
    /// Vrai partout sauf pour une mise à jour qui contient un incrément : celui-ci est
    /// **relatif**, donc le rejouer compterait deux fois.
    public var isIdempotent: Bool {
        switch self {
        case .set, .delete: true
        case let .update(_, fields): fields.values.allSatisfy { !$0.isRelative }
        }
    }
}

/// Un lot d'écritures appliqué d'un seul coup.
///
/// Firestore garantit qu'un lot est **atomique** : ou toutes les écritures passent, ou
/// aucune. C'est ce qui permet de maintenir un invariant entre plusieurs documents sans
/// fenêtre d'incohérence.
///
/// ```swift
/// try await store.batch { batch in
///     batch.set(profile, at: .profiles.document(profile.id), merge: true)
///     batch.update(["count": 3], at: .stats.document("global"))
///     batch.delete(at: .drafts.document(draftID))
/// }
/// ```
///
/// > Un lot est limité à **500 écritures** côté Firestore. Au-delà, découpez.
/// > Le nom évite `WriteBatch`, déjà pris par le SDK Firebase.
public struct DocumentBatch: Sendable {

    /// La limite imposée par Firestore.
    public static let maximumOperations = 500

    public private(set) var operations: [DocumentWrite] = []

    public init() {}

    /// Écrit `value`, en remplaçant le document ou en fusionnant avec lui.
    ///
    /// - Parameter merge: `false` remplace le document entier — les champs absents de
    ///   `value` disparaissent. `true` ne touche qu'aux champs fournis.
    public mutating func set<Value: FirestoreValue>(
        _ value: Value,
        at path: DocumentPath<Value>,
        merge: Bool = false
    ) {
        operations.append(.set(path: path.path, value: value, merge: merge))
    }

    /// Met à jour des champs d'un document qui doit exister.
    public mutating func update<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        at path: DocumentPath<Value>
    ) {
        operations.append(.update(path: path.path, fields: fields))
    }

    /// Supprime un document. Supprimer un document absent n'est pas une erreur.
    public mutating func delete<Value: FirestoreValue>(at path: DocumentPath<Value>) {
        operations.append(.delete(path: path.path))
    }

    // MARK: - Par collection et identifiant

    /// Les trois opérations ci-dessus, désignées par `id` **dans** une collection.
    ///
    /// ```swift
    /// batch.set(profile, id: "u1", in: .profiles, merge: true)
    /// ```
    public mutating func set<Value: FirestoreValue>(
        _ value: Value,
        id: String,
        in collection: CollectionPath<Value>,
        merge: Bool = false
    ) {
        set(value, at: collection.document(id), merge: merge)
    }

    public mutating func update<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        id: String,
        in collection: CollectionPath<Value>
    ) {
        update(fields, at: collection.document(id))
    }

    public mutating func delete<Value: FirestoreValue>(
        id: String,
        in collection: CollectionPath<Value>
    ) {
        delete(at: collection.document(id))
    }

    /// Vrai si le lot dépasse la limite de Firestore.
    public var exceedsLimit: Bool {
        operations.count > Self.maximumOperations
    }
}
