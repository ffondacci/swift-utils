import Foundation

/// Garder localement un ensemble de valeurs — ce qu'une API a rendu, des brouillons, un
/// catalogue.
///
/// Là où une ``PersistenceKey`` désigne une valeur, une ``PersistenceCollection`` en
/// désigne un nombre quelconque, adressées par identifiant.
///
/// > Note : contrairement aux valeurs simples, les collections **ne passent pas par le
/// > cache** du store. Mettre des milliers d'entrées dans un dictionnaire observé ferait
/// > redessiner toutes les vues à chaque écriture. Leurs lectures sont donc `async` et
/// > vont toujours au support.
extension PersistenceStore {

    /// Range `value` sous `id`.
    public func save<Value: PersistentValue>(
        _ value: Value,
        id: String,
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) {
        try await repository.save(value, id: id, in: collection)
    }

    /// Range plusieurs entrées d'un coup.
    ///
    /// - Parameter values: les valeurs par identifiant.
    public func saveAll<Value: PersistentValue>(
        _ values: [String: Value],
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) {
        for (id, value) in values {
            try await repository.save(value, id: id, in: collection)
        }
    }

    /// L'entrée `id`, ou `nil` si elle n'existe pas.
    public func load<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> Value? {
        try await repository.load(id: id, from: collection)
    }

    /// L'entrée `id` avec sa date d'écriture, ou `nil`.
    public func stored<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> StoredValue<Value>? {
        try await repository.stored(id: id, from: collection)
    }

    /// Toutes les entrées, par identifiant.
    ///
    /// - Throws: ``PersistenceError/decodingFailed(key:type:reason:)`` dès qu'une entrée
    ///   est illisible. Après un changement de modèle, le réflexe est d'attraper et de
    ///   vider :
    ///
    ///   ```swift
    ///   do {
    ///       return try await store.loadAll(from: .profiles)
    ///   } catch {
    ///       try await store.removeAll(from: .profiles)
    ///       return [:]
    ///   }
    ///   ```
    public func loadAll<Value: PersistentValue>(
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> [String: Value] {
        try await repository.loadAll(from: collection)
    }

    /// Les entrées qui satisfont `predicate`.
    ///
    /// Le filtrage a lieu en mémoire, après chargement : ce n'est pas une requête de base
    /// de données.
    public func filter<Value: PersistentValue>(
        _ collection: PersistenceCollection<Value>,
        where predicate: @Sendable (Value) -> Bool
    ) async throws(PersistenceError) -> [Value] {
        try await repository.filter(collection, where: predicate)
    }

    /// Les identifiants présents, sans charger les valeurs.
    public func ids<Value: PersistentValue>(
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> [String] {
        try await repository.ids(in: collection)
    }

    /// Le nombre d'entrées, sans charger les valeurs.
    public func count<Value: PersistentValue>(
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> Int {
        try await repository.ids(in: collection).count
    }

    /// Supprime l'entrée `id`.
    public func remove<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) {
        try await repository.remove(id: id, from: collection)
    }

    /// Vide la collection, sans toucher au reste du stockage.
    public func removeAll<Value: PersistentValue>(
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) {
        try await repository.removeAll(from: collection)
    }
}
