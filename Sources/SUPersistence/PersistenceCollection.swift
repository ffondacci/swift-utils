import Foundation

/// Un ensemble de valeurs de même type, adressées par identifiant.
///
/// Là où une ``PersistenceKey`` désigne **une** valeur, une collection en désigne un
/// nombre quelconque : les profils en cache, les objets d'un catalogue, les brouillons.
/// C'est ce qu'il faut pour garder localement ce qu'une API a rendu.
///
/// **Le module n'en déclare aucune** — comme pour les clés, chaque app déclare les siennes.
///
/// ```swift
/// extension PersistenceCollection where Value == Profile {
///     static let profiles = PersistenceCollection("profiles")
/// }
///
/// try await store.save(profile, id: profile.id, in: .profiles)
/// let all = try await store.loadAll(from: .profiles)
/// let actifs = try await store.filter(.profiles) { $0.visits > 10 }
/// ```
public struct PersistenceCollection<Value: PersistentValue>: Sendable {

    /// Le nom de la collection. Stable dans le temps : le renommer revient à perdre tout
    /// ce qu'elle contenait.
    public let name: String

    /// - Parameter name: sans `/`, qui sert de séparateur interne.
    public init(_ name: String) {
        precondition(!name.contains("/"), "un nom de collection ne peut pas contenir « / »")
        self.name = name
    }

    /// Le préfixe sous lequel toutes ses entrées sont rangées.
    ///
    /// Il isole les collections des clés simples et les unes des autres : une collection
    /// `profiles` et une clé `profiles` ne se croisent jamais.
    var storagePrefix: String { "collection/\(name)/" }

    /// La clé de stockage d'une entrée.
    func storageKey(for id: String) -> StorageKey {
        StorageKey("\(storagePrefix)\(id)")
    }

    /// L'identifiant extrait d'une clé de stockage, ou `nil` si elle n'appartient pas à
    /// cette collection.
    func id(from key: StorageKey) -> String? {
        guard key.rawValue.hasPrefix(storagePrefix) else { return nil }
        return String(key.rawValue.dropFirst(storagePrefix.count))
    }
}
