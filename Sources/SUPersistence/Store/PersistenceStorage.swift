import Foundation

/// Le support à utiliser, pour les cas déjà fournis par le module.
///
/// C'est le **seul** endroit qui énumère les backends disponibles. Ajouter un support
/// revient à ajouter un cas ici et une conformance à `PersistenceBackend` — rien d'autre
/// ne bouge. Et pour un backend maison, `PersistenceStore.init(repository:)` évite même
/// d'y toucher.
public enum PersistenceStorage: Sendable {

    /// `UserDefaults.standard`. Le défaut, adapté aux petites valeurs de préférence.
    case userDefaults

    /// Une suite `UserDefaults` dédiée — app group partagé, ou isolation d'un test.
    case userDefaultsSuite(named: String)

    /// Un document JSON dans Application Support. Adapté aux valeurs structurées, et
    /// inspectable à la main.
    case jsonFile(named: String)

    /// Rien n'atteint le disque. Pour les previews SwiftUI et les tests.
    case inMemory

    func makeRepository() throws(PersistenceError) -> any PersistenceRepository {
        switch self {
        case .userDefaults:
            CodableRepository(backend: UserDefaultsBackend())
        case let .userDefaultsSuite(name):
            CodableRepository(backend: try UserDefaultsBackend(suiteName: name))
        case let .jsonFile(name):
            CodableRepository(backend: try JSONFileBackend(named: name))
        case .inMemory:
            CodableRepository(backend: InMemoryBackend())
        }
    }
}
