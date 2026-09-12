import Foundation

/// Le repository standard : un backend pour les octets, un codeur pour les convertir.
///
/// Il est sans état — toute la synchronisation vit dans le backend, qui est un acteur.
/// C'est pour ça que c'est une `struct` et non un `actor` de plus : un saut d'isolation
/// gratuit serait un saut de trop.
public struct CodableRepository: PersistenceRepository {

    private let backend: any PersistenceBackend
    private let coder: any ValueCoder

    /// - Parameters:
    ///   - backend: où les octets sont rangés.
    ///   - coder: comment les valeurs deviennent des octets.
    public init(backend: any PersistenceBackend, coder: any ValueCoder = JSONValueCoder()) {
        self.backend = backend
        self.coder = coder
    }

    public func load<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) -> Value {
        guard let data = try await backend.read(key.storageKey) else {
            return key.defaultValue
        }
        do {
            return try coder.decode(Value.self, from: data)
        } catch {
            throw .decodingFailed(key: key.name, type: "\(Value.self)", reason: error.reason)
        }
    }

    public func save<Value: PersistentValue>(
        _ value: Value,
        for key: PersistenceKey<Value>
    ) async throws(PersistenceError) {
        let data: Data
        do {
            data = try coder.encode(value)
        } catch {
            throw .encodingFailed(key: key.name, type: "\(Value.self)", reason: error.reason)
        }
        try await backend.write(data, for: key.storageKey)
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

    public func removeAll() async throws(PersistenceError) {
        try await backend.removeAll()
    }
}
