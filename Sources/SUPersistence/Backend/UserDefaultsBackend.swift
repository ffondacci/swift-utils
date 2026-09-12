import Foundation

/// Le backend `UserDefaults`, pour les petites valeurs de préférence.
///
/// Il ne range que du `Data` : la sérialisation est le travail de la couche du dessus, et
/// `UserDefaults` n'a pas à savoir ce qu'il porte.
///
/// > Important : `removeAll()` n'efface que les clés écrites via ce backend, suivies dans
/// > un index dédié. Effacer la suite entière détruirait des réglages système et ceux
/// > d'autres parties de l'app.
public actor UserDefaultsBackend: PersistenceBackend {

    /// La clé sous laquelle on tient l'inventaire de ce qu'on a écrit.
    private static let indexKey = "com.swift-utils.persistence.index"

    private let defaults: UserDefaults

    /// Ouvre `UserDefaults.standard`. Ne peut pas échouer.
    public init() {
        self.defaults = .standard
    }

    /// Ouvre une suite dédiée — app group, ou isolation d'un test.
    ///
    /// La suite est ouverte *à l'intérieur* de l'acteur plutôt que reçue en paramètre :
    /// `UserDefaults` n'est pas `Sendable`, et l'instance ne doit donc jamais traverser
    /// une frontière d'isolation.
    public init(suiteName: String) throws(PersistenceError) {
        guard let suite = UserDefaults(suiteName: suiteName) else {
            throw .storageUnavailable(reason: "suite UserDefaults « \(suiteName) » introuvable")
        }
        self.defaults = suite
    }

    public func read(_ key: StorageKey) throws(PersistenceError) -> Data? {
        defaults.data(forKey: key.rawValue)
    }

    public func write(_ data: Data, for key: StorageKey) throws(PersistenceError) {
        defaults.set(data, forKey: key.rawValue)
        var index = writtenKeys
        index.insert(key.rawValue)
        defaults.set(Array(index), forKey: Self.indexKey)
    }

    public func remove(_ key: StorageKey) throws(PersistenceError) {
        defaults.removeObject(forKey: key.rawValue)
        var index = writtenKeys
        index.remove(key.rawValue)
        defaults.set(Array(index), forKey: Self.indexKey)
    }

    public func contains(_ key: StorageKey) throws(PersistenceError) -> Bool {
        defaults.data(forKey: key.rawValue) != nil
    }

    public func removeAll() throws(PersistenceError) {
        for key in writtenKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.removeObject(forKey: Self.indexKey)
    }

    private var writtenKeys: Set<String> {
        Set(defaults.stringArray(forKey: Self.indexKey) ?? [])
    }
}
