import Foundation

/// Ce qu'une valeur doit savoir faire pour être persistée : se sérialiser, et traverser
/// les frontières d'isolation.
public typealias PersistentValue = Codable & Sendable

/// Une clé typée : elle lie un nom de stockage au type de la valeur qu'il contient, et à
/// la valeur rendue quand rien n'a encore été écrit.
///
/// Le typage est ce qui rend l'API du store sûre — `store.value(for: .onboardingDone)`
/// rend un `Bool`, pas un `Any` à déballer. Déclarez vos clés en extension, groupées par
/// type :
///
/// ```swift
/// extension PersistenceKey where Value == Bool {
///     static let onboardingDone = PersistenceKey("onboardingDone", default: false)
/// }
/// ```
///
/// Pour une valeur qui peut légitimement être absente, typez-la en optionnel :
///
/// ```swift
/// extension PersistenceKey where Value == Profile? {
///     static let currentProfile = PersistenceKey("currentProfile", default: nil)
/// }
/// ```
public struct PersistenceKey<Value: PersistentValue>: Sendable {

    /// Le nom sous lequel la valeur est rangée. Stable dans le temps : le renommer revient
    /// à perdre la donnée déjà écrite.
    public let name: String

    /// Ce que l'on rend quand la clé n'a jamais été écrite, ou vient d'être supprimée.
    public let defaultValue: Value

    public init(_ name: String, default defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }

    /// La clé telle que la couche de stockage la voit, dépouillée de son type.
    var storageKey: StorageKey { StorageKey(name) }
}
