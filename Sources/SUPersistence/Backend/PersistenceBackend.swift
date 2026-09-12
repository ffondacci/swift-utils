import Foundation

/// Une clé vue par la couche de stockage : un nom, sans type.
///
/// Le backend ne manipule que des octets, il n'a donc rien à savoir de ce qui est rangé.
/// C'est `PersistenceKey` qui porte le type, une couche plus haut.
public struct StorageKey: Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.init(value) }
}

/// Le support physique : il range des octets sous une clé, et sait les relire.
///
/// C'est le seul endroit du module qui connaît `UserDefaults`, le système de fichiers, ou
/// demain SQLite. Ajouter un support revient à écrire une conformance ici — aucune couche
/// supérieure ne doit changer. Si elle doit changer, c'est que l'abstraction fuit.
///
/// Toutes les opérations sont `async` : un backend est libre d'être un `actor`, et la
/// plupart le sont, parce que le stockage est un état partagé.
public protocol PersistenceBackend: Sendable {

    /// Les octets rangés sous `key`, ou `nil` si rien n'y a jamais été écrit.
    func read(_ key: StorageKey) async throws(PersistenceError) -> Data?

    /// Range `data` sous `key`, en écrasant ce qui s'y trouvait.
    func write(_ data: Data, for key: StorageKey) async throws(PersistenceError)

    /// Supprime `key`. Supprimer une clé absente n'est pas une erreur.
    func remove(_ key: StorageKey) async throws(PersistenceError)

    /// Indique si `key` porte des octets.
    func contains(_ key: StorageKey) async throws(PersistenceError) -> Bool

    /// Vide tout ce que ce backend a écrit — et rien d'autre.
    func removeAll() async throws(PersistenceError)

    /// Les clés écrites qui commencent par `prefix`, dans un ordre indéterminé.
    ///
    /// C'est ce qui rend les collections possibles. Les trois backends du module
    /// suivaient déjà leurs clés pour `removeAll()`, donc la méthode ne leur coûte rien —
    /// un backend qui ne saurait pas énumérer devrait le faire savoir en rendant un
    /// tableau vide, jamais en mentant.
    func keys(withPrefix prefix: String) async throws(PersistenceError) -> [StorageKey]
}
