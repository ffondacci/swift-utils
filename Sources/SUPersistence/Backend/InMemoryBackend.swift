import Foundation

/// Un backend qui ne survit pas au processus.
///
/// Il sert à trois choses : les tests, les previews SwiftUI, et un store volontairement
/// éphémère. Comme il implémente le même contrat que les autres, un test écrit contre lui
/// vaut pour tous.
public actor InMemoryBackend: PersistenceBackend {

    private var storage: [StorageKey: Data]

    /// - Parameter storage: un contenu initial, pratique pour poser un état de départ en
    ///   preview ou en test.
    public init(storage: [StorageKey: Data] = [:]) {
        self.storage = storage
    }

    public func read(_ key: StorageKey) throws(PersistenceError) -> Data? {
        storage[key]
    }

    public func write(_ data: Data, for key: StorageKey) throws(PersistenceError) {
        storage[key] = data
    }

    public func remove(_ key: StorageKey) throws(PersistenceError) {
        storage.removeValue(forKey: key)
    }

    public func contains(_ key: StorageKey) throws(PersistenceError) -> Bool {
        storage[key] != nil
    }

    public func removeAll() throws(PersistenceError) {
        storage.removeAll()
    }

    public func keys(withPrefix prefix: String) throws(PersistenceError) -> [StorageKey] {
        storage.keys.filter { $0.rawValue.hasPrefix(prefix) }
    }
}
