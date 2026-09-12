import Foundation

/// Le nom d'une chose qu'on peut avoir déjà vue — un écran d'onboarding, une explication
/// de permission, une nouveauté à signaler une seule fois.
///
/// Déclarez les vôtres en extension :
///
/// ```swift
/// extension SeenKey {
///     static let onboarding: SeenKey = "onboarding"
///     static let cameraExplainer: SeenKey = "cameraExplainer"
/// }
/// ```
///
/// C'est un type distinct de `PersistenceKey` volontairement : une marque « déjà vu » se
/// manipule avec un vocabulaire à elle, et ne peut pas être confondue avec une préférence
/// booléenne ordinaire.
public struct SeenKey: Sendable, Hashable, ExpressibleByStringLiteral {

    /// Le nom de la marque. Stable dans le temps : le renommer revient à faire oublier à
    /// l'app ce qu'elle avait déjà montré.
    public let name: String

    public init(_ name: String) { self.name = name }
    public init(stringLiteral value: String) { self.init(value) }

    /// La clé de stockage sous-jacente.
    ///
    /// Le préfixe garantit qu'une marque nommée `onboarding` n'écrase jamais une
    /// préférence nommée `onboarding` — les deux espaces de noms sont indépendants.
    var persistenceKey: PersistenceKey<Bool> {
        PersistenceKey("seen.\(name)", default: false)
    }
}
