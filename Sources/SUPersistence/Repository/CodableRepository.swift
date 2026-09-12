import Foundation

/// Le repository standard : un backend pour les octets, un codeur pour les convertir.
///
/// Il est sans état — toute la synchronisation vit dans le backend, qui est un acteur.
/// C'est pour ça que c'est une `struct` et non un `actor` de plus : un saut d'isolation
/// gratuit serait un saut de trop.
///
/// Toute valeur est écrite emballée dans un ``StoredValue``, donc horodatée. Le surcoût
/// est d'un champ `Date` par entrée, et il évite d'avoir à tenir un registre de fraîcheur
/// à côté du stockage.
public struct CodableRepository: PersistenceRepository {

    private let backend: any PersistenceBackend
    private let coder: any ValueCoder

    public init(backend: any PersistenceBackend, coder: any ValueCoder = JSONValueCoder()) {
        self.backend = backend
        self.coder = coder
    }

    // MARK: - Valeurs

    public func load<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) -> Value {
        try await stored(key)?.value ?? key.defaultValue
    }

    public func stored<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) -> StoredValue<Value>? {
        try await read(key.storageKey, named: key.name)
    }

    public func save<Value: PersistentValue>(
        _ value: Value,
        for key: PersistenceKey<Value>
    ) async throws(PersistenceError) {
        try await write(value, to: key.storageKey, named: key.name)
    }

    public func remove<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) {
        try await backend.remove(key.storageKey)
    }

    public func contains<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) -> Bool {
        try await backend.contains(key.storageKey)
    }

    // MARK: - Collections

    public func save<Value: PersistentValue>(
        _ value: Value,
        id: String,
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) {
        try await write(value, to: collection.storageKey(for: id), named: "\(collection.name)/\(id)")
    }

    public func load<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> Value? {
        try await stored(id: id, from: collection)?.value
    }

    public func stored<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> StoredValue<Value>? {
        try await read(collection.storageKey(for: id), named: "\(collection.name)/\(id)")
    }

    @concurrent
    public func loadAll<Value: PersistentValue>(
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> [String: Value] {
        let keys = try await backend.keys(withPrefix: collection.storagePrefix)

        var values: [String: Value] = [:]
        values.reserveCapacity(keys.count)

        for key in keys {
            guard let id = collection.id(from: key) else { continue }
            guard let entry: StoredValue<Value> = try await read(key, named: "\(collection.name)/\(id)") else {
                continue
            }
            values[id] = entry.value
        }
        return values
    }

    public func ids<Value: PersistentValue>(
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> [String] {
        try await backend.keys(withPrefix: collection.storagePrefix)
            .compactMap { collection.id(from: $0) }
    }

    public func remove<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) {
        try await backend.remove(collection.storageKey(for: id))
    }

    public func removeAll<Value: PersistentValue>(
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) {
        for key in try await backend.keys(withPrefix: collection.storagePrefix) {
            try await backend.remove(key)
        }
    }

    // MARK: - Tout

    public func removeAll() async throws(PersistenceError) {
        try await backend.removeAll()
    }

    // MARK: - Octets

    private func write<Value: PersistentValue>(
        _ value: Value,
        to storageKey: StorageKey,
        named name: String
    ) async throws(PersistenceError) {
        let data: Data
        do {
            data = try coder.encode(StoredValue(value: value))
        } catch {
            throw .encodingFailed(key: name, type: "\(Value.self)", reason: error.reason)
        }
        try await backend.write(data, for: storageKey)
    }

    private func read<Value: PersistentValue>(
        _ storageKey: StorageKey,
        named name: String
    ) async throws(PersistenceError) -> StoredValue<Value>? {
        guard let data = try await backend.read(storageKey) else { return nil }
        do {
            return try coder.decode(StoredValue<Value>.self, from: data)
        } catch {
            throw .decodingFailed(key: name, type: "\(Value.self)", reason: error.reason)
        }
    }
}
