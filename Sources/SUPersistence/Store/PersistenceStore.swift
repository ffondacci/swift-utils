import Foundation
import Observation

/// Le point d'entrée du module, et la seule chose que l'app manipule au quotidien.
///
/// Il se place au-dessus des couches — repository, codeur, backend — et n'en expose
/// aucune. Sa signature ne mentionne ni `UserDefaults`, ni `URL`, ni `Data` : changer de
/// support ne change rien au code appelant.
///
/// ## Injection
///
/// ```swift
/// @main struct LensyApp: App {
///     var body: some Scene {
///         WindowGroup { RootView() }
///             .environment(PersistenceStore.shared)
///     }
/// }
/// ```
///
/// ## Lecture dans une vue
///
/// ```swift
/// struct RootView: View {
///     @Environment(PersistenceStore.self) private var store
///
///     var body: some View {
///         Toggle("Onboarding vu", isOn: .constant(store[.onboardingDone]))
///             .task { try? await store.load(.onboardingDone) }
///     }
/// }
/// ```
///
/// La lecture est **synchrone et observée** : elle rend ce qui est en cache, et la vue se
/// redessine quand le cache change. C'est `load(_:)` qui va chercher la valeur sur le
/// support, et `save(_:for:)` qui l'y écrit.
///
/// > Note : l'observation porte sur le cache entier. Écrire une clé invalide les vues qui
/// > en lisent une autre. C'est sans conséquence à l'échelle d'un jeu de préférences ;
/// > pour des milliers d'entrées, il faudrait découper.
@MainActor
@Observable
public final class PersistenceStore {

    /// L'instance partagée, adossée à `UserDefaults.standard`.
    ///
    /// Pour un autre support, construisez votre propre store plutôt que de reconfigurer
    /// celui-ci : un singleton dont le stockage change en cours de route est une source
    /// de bugs difficiles à reproduire.
    public static let shared = PersistenceStore(
        repository: CodableRepository(backend: UserDefaultsBackend())
    )

    @ObservationIgnored private let repository: any PersistenceRepository

    /// Les valeurs déjà chargées. C'est ce que `@Observable` suit.
    private var cache: [String: any Sendable] = [:]

    /// Construit un store sur un repository quelconque — y compris un double de test ou
    /// un backend maison.
    public init(repository: any PersistenceRepository) {
        self.repository = repository
    }

    /// Construit un store sur l'un des supports fournis par le module.
    public convenience init(_ storage: PersistenceStorage) throws(PersistenceError) {
        self.init(repository: try storage.makeRepository())
    }

    /// Un store qui ne persiste rien, pour les previews SwiftUI et les tests.
    public static func inMemory() -> PersistenceStore {
        PersistenceStore(repository: CodableRepository(backend: InMemoryBackend()))
    }

    // MARK: - Lecture

    /// La valeur en cache pour `key`, ou sa valeur par défaut si elle n'a pas encore été
    /// chargée.
    ///
    /// Synchrone et observée : appelable directement dans un `body`. Elle ne touche pas au
    /// support — c'est `load(_:)` qui remplit le cache.
    public func value<Value: PersistentValue>(for key: PersistenceKey<Value>) -> Value {
        cache[key.name] as? Value ?? key.defaultValue
    }

    /// Raccourci de ``value(for:)``.
    public subscript<Value: PersistentValue>(key: PersistenceKey<Value>) -> Value {
        value(for: key)
    }

    /// Lit la valeur depuis le support et met le cache à jour.
    ///
    /// - Returns: la valeur lue, ou la valeur par défaut de la clé si rien n'a été écrit.
    /// - Throws: ``PersistenceError/readFailed(key:reason:)`` si le support est illisible,
    ///   ``PersistenceError/decodingFailed(key:type:reason:)`` si les octets ne
    ///   correspondent plus au type attendu.
    @discardableResult
    public func load<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) -> Value {
        let value = try await repository.load(key)
        cache[key.name] = value
        return value
    }

    /// Indique si une valeur a été écrite sous `key`.
    ///
    /// À distinguer de « la valeur vaut son défaut » : une clé peut porter une valeur
    /// égale à son défaut.
    public func contains<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) -> Bool {
        try await repository.contains(key)
    }

    // MARK: - Écriture

    /// Écrit la valeur sur le support, puis met le cache à jour.
    ///
    /// L'ordre compte : le cache ne bouge qu'une fois l'écriture confirmée. Une écriture
    /// qui échoue laisse donc l'interface sur l'ancienne valeur, ce qui est le
    /// comportement honnête.
    ///
    /// - Throws: ``PersistenceError/encodingFailed(key:type:reason:)`` si la valeur n'est
    ///   pas sérialisable, ``PersistenceError/writeFailed(key:reason:)`` si le support
    ///   refuse l'écriture.
    public func save<Value: PersistentValue>(
        _ value: Value,
        for key: PersistenceKey<Value>
    ) async throws(PersistenceError) {
        try await repository.save(value, for: key)
        cache[key.name] = value
    }

    /// Supprime la valeur de `key`. Une lecture ultérieure rendra sa valeur par défaut.
    public func remove<Value: PersistentValue>(
        _ key: PersistenceKey<Value>
    ) async throws(PersistenceError) {
        try await repository.remove(key)
        cache.removeValue(forKey: key.name)
    }

    /// Efface tout ce que ce store a écrit, et vide le cache.
    public func removeAll() async throws(PersistenceError) {
        try await repository.removeAll()
        cache.removeAll()
    }
}
