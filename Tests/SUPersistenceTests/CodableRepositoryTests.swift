import Foundation
import Testing
@testable import SUPersistence

/// La couche typée : valeurs par défaut, encodage, et traduction des erreurs.
///
/// Elle est testée derrière un `InMemoryBackend` — un test de repository qui toucherait
/// le disque testerait la mauvaise chose.
@Suite("Repository typé")
struct CodableRepositoryTests {

    private func makeRepository(
        storage: [StorageKey: Data] = [:]
    ) -> CodableRepository {
        CodableRepository(backend: InMemoryBackend(storage: storage))
    }

    @Test("une clé jamais écrite rend sa valeur par défaut")
    func missingKeyFallsBackToDefault() async throws {
        let repository = makeRepository()

        let flag = try await repository.load(.onboardingDone)
        let count = try await repository.load(.launchCount)
        let profile = try await repository.load(.profile)

        #expect(flag == false)
        #expect(count == 0)
        #expect(profile.name == "anonyme")
    }

    @Test("une valeur structurée survit à l'aller-retour")
    func structuredRoundTrip() async throws {
        let repository = makeRepository()
        let profile = Profile(
            name: "Florent",
            visits: 12,
            lastSeen: Date(timeIntervalSince1970: 1_700_000_000)
        )

        try await repository.save(profile, for: .profile)

        let reread = try await repository.load(.profile)
        #expect(reread == profile)
    }

    @Test("une valeur optionnelle nulle se distingue d'une clé absente")
    func optionalIsNotAbsence() async throws {
        let repository = makeRepository()
        let profile = Profile(name: "Florent", visits: 1, lastSeen: nil)

        try await repository.save(profile, for: .profile)

        let present = try await repository.contains(.profile)
        let reread = try await repository.load(.profile)

        #expect(present == true)
        #expect(reread.lastSeen == nil)
    }

    @Test("supprimer une clé ramène sa valeur par défaut")
    func removeRestoresDefault() async throws {
        let repository = makeRepository()
        try await repository.save(true, for: .onboardingDone)

        try await repository.remove(.onboardingDone)

        let value = try await repository.load(.onboardingDone)
        let present = try await repository.contains(.onboardingDone)

        #expect(value == false)
        #expect(present == false)
    }

    @Test("des octets illisibles remontent une erreur, jamais un défaut silencieux")
    func corruptedDataThrows() async throws {
        let repository = makeRepository(
            storage: ["profile": Data("ceci n'est pas du JSON".utf8)]
        )

        let error = await #expect(throws: PersistenceError.self) {
            try await repository.load(.profile)
        }

        guard case let .decodingFailed(key, type, _) = error else {
            Issue.record("erreur inattendue : \(String(describing: error))")
            return
        }
        #expect(key == "profile")
        #expect(type == "Profile")
    }

    @Test("l'erreur de décodage porte de quoi diagnostiquer sans debugger")
    func errorCarriesContext() async throws {
        let repository = makeRepository(storage: ["profile": Data([0xFF])])

        let error = await #expect(throws: PersistenceError.self) {
            try await repository.load(.profile)
        }

        #expect(error?.key == "profile")
        #expect(error?.description.contains("profile") == true)
    }

    @Test("removeAll efface toutes les clés")
    func removeAllClearsEverything() async throws {
        let repository = makeRepository()
        try await repository.save(true, for: .onboardingDone)
        try await repository.save(42, for: .launchCount)

        try await repository.removeAll()

        let present = try await repository.contains(.onboardingDone)
        let count = try await repository.load(.launchCount)

        #expect(present == false)
        #expect(count == 0)
    }
}
