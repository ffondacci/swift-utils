import Foundation
import Testing
@testable import SUPersistence

// MARK: - Supports à tester

/// Les backends soumis au contrat commun.
///
/// Toute conformance à `PersistenceBackend` ajoutée au module doit apparaître ici : c'est
/// ce qui garantit que les supports sont réellement interchangeables.
enum BackendFixture: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case inMemory
    case userDefaults
    case jsonFile
    case jsonDirectory

    var testDescription: String { rawValue }
}

/// Fabrique un backend neuf, le prête au test, puis nettoie derrière lui.
///
/// Chaque appel travaille sur un stockage unique — suite `UserDefaults` ou dossier
/// temporaire nommés par UUID — pour qu'aucun test n'en pollue un autre, même exécutés en
/// parallèle.
func withBackend<T>(
    _ fixture: BackendFixture,
    _ body: (any PersistenceBackend) async throws -> T
) async throws -> T {
    switch fixture {
    case .inMemory:
        return try await body(InMemoryBackend())

    case .userDefaults:
        let suiteName = "com.swift-utils.tests.\(UUID().uuidString)"
        let backend = try UserDefaultsBackend(suiteName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        return try await body(backend)

    case .jsonFile:
        let directory = temporaryDirectory()
        let backend = JSONFileBackend(fileURL: directory.appending(path: "store.json"))
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(backend)

    case .jsonDirectory:
        let directory = temporaryDirectory()
        let backend = JSONDirectoryBackend(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(backend)
    }
}

/// Un dossier temporaire propre à un test. Jamais le dossier de l'utilisateur.
func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "su-persistence-tests", directoryHint: .isDirectory)
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
}

// MARK: - Valeurs de test

struct Profile: Codable, Sendable, Equatable {
    var name: String
    var visits: Int
    var lastSeen: Date?
}

extension PersistenceKey where Value == Profile {
    static let profile = PersistenceKey(
        "profile",
        default: Profile(name: "anonyme", visits: 0, lastSeen: nil)
    )
}

extension PersistenceKey where Value == Bool {
    static let onboardingDone = PersistenceKey("onboardingDone", default: false)
}

extension PersistenceKey where Value == Int {
    static let launchCount = PersistenceKey("launchCount", default: 0)
}

// MARK: - Doubles

/// Un repository qui échoue à tous les coups, pour vérifier ce que le store fait d'une
/// erreur plutôt que d'un succès.
struct FailingRepository: PersistenceRepository {
    let error: PersistenceError

    func load<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> Value {
        throw error
    }

    func stored<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> StoredValue<Value>? {
        throw error
    }

    func save<Value: PersistentValue>(_ value: Value, for key: PersistenceKey<Value>) async throws(PersistenceError) {
        throw error
    }

    func remove<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) {
        throw error
    }

    func contains<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> Bool {
        throw error
    }

    func save<Value: PersistentValue>(_ value: Value, id: String, in collection: PersistenceCollection<Value>) async throws(PersistenceError) {
        throw error
    }

    func load<Value: PersistentValue>(id: String, from collection: PersistenceCollection<Value>) async throws(PersistenceError) -> Value? {
        throw error
    }

    func stored<Value: PersistentValue>(id: String, from collection: PersistenceCollection<Value>) async throws(PersistenceError) -> StoredValue<Value>? {
        throw error
    }

    func loadAll<Value: PersistentValue>(from collection: PersistenceCollection<Value>) async throws(PersistenceError) -> [String: Value] {
        throw error
    }

    func ids<Value: PersistentValue>(in collection: PersistenceCollection<Value>) async throws(PersistenceError) -> [String] {
        throw error
    }

    func remove<Value: PersistentValue>(id: String, from collection: PersistenceCollection<Value>) async throws(PersistenceError) {
        throw error
    }

    func removeAll<Value: PersistentValue>(from collection: PersistenceCollection<Value>) async throws(PersistenceError) {
        throw error
    }

    func removeAll() async throws(PersistenceError) {
        throw error
    }
}

// MARK: - Collections de test

extension PersistenceCollection where Value == Profile {
    static let profiles = PersistenceCollection("profiles")
}

extension PersistenceCollection where Value == Int {
    static let scores = PersistenceCollection("scores")
}
