import Foundation

/// Ce qu'une valeur doit savoir faire pour aller dans Firestore : se sérialiser, et
/// traverser les frontières d'isolation.
public typealias FirestoreValue = Codable & Sendable

/// Le chemin d'une collection, typé par ce qu'elle contient.
///
/// **Le module n'en déclare aucun.** Comme les clés de `SUPersistence` et les endpoints de
/// `SUNetworking`, ils appartiennent au domaine de l'app.
///
/// ```swift
/// extension CollectionPath where Value == Profile {
///     static let profiles = CollectionPath("profiles")
/// }
///
/// try await store.setDocument(profile, at: .profiles.document(profile.id))
/// ```
public struct CollectionPath<Value: FirestoreValue>: Sendable, Hashable {

    /// Le chemin complet, segments séparés par `/`.
    public let path: String

    /// - Parameter path: `"profiles"`, ou `"users/u1/posts"` pour une sous-collection.
    ///   Un chemin de collection compte toujours un **nombre impair** de segments.
    public init(_ path: String) {
        let segments = Self.segments(of: path)
        precondition(!segments.isEmpty, "un chemin de collection ne peut pas être vide")
        precondition(
            segments.count.isMultiple(of: 2) == false,
            "« \(path) » a \(segments.count) segments : un chemin de collection en compte un nombre impair"
        )
        self.path = segments.joined(separator: "/")
    }

    /// Le document `id` de cette collection.
    public func document(_ id: String) -> DocumentPath<Value> {
        DocumentPath("\(path)/\(id)")
    }

    /// Le dernier segment — le nom de la collection, sans ses parents.
    public var name: String {
        Self.segments(of: path).last ?? path
    }

    static func segments(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }
}

/// Le chemin d'un document, typé par ce qu'il contient.
public struct DocumentPath<Value: FirestoreValue>: Sendable, Hashable {

    /// Le chemin complet, segments séparés par `/`.
    public let path: String

    /// - Parameter path: `"profiles/u1"`. Un chemin de document compte toujours un
    ///   **nombre pair** de segments.
    public init(_ path: String) {
        let segments = CollectionPath<Value>.segments(of: path)
        precondition(
            segments.count >= 2 && segments.count.isMultiple(of: 2),
            "« \(path) » a \(segments.count) segments : un chemin de document en compte un nombre pair"
        )
        self.path = segments.joined(separator: "/")
    }

    /// L'identifiant du document — son dernier segment.
    public var id: String {
        CollectionPath<Value>.segments(of: path).last ?? path
    }

    /// La collection qui le contient.
    public var collection: CollectionPath<Value> {
        CollectionPath(CollectionPath<Value>.segments(of: path).dropLast().joined(separator: "/"))
    }

    /// Une sous-collection de ce document.
    ///
    /// ```swift
    /// let posts: CollectionPath<Post> = .profiles.document("u1").collection("posts")
    /// ```
    public func collection<Child: FirestoreValue>(
        _ name: String,
        of type: Child.Type = Child.self
    ) -> CollectionPath<Child> {
        CollectionPath("\(path)/\(name)")
    }
}

/// Un document lu, avec son identifiant.
///
/// Les requêtes rendent un tableau plutôt qu'un dictionnaire : un `order(by:)` n'a de sens
/// que si l'ordre survit à la lecture.
public struct FirestoreDocument<Value: FirestoreValue>: Sendable {
    public let id: String
    public let value: Value

    /// D'où vient cette lecture, et si des écritures locales attendent encore.
    public let metadata: FirestoreMetadata

    public init(id: String, value: Value, metadata: FirestoreMetadata = .synchronized) {
        self.id = id
        self.value = value
        self.metadata = metadata
    }
}

extension FirestoreDocument: Equatable where Value: Equatable {}
