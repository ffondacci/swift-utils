import Foundation
import Testing
@testable import SUPersistence

/// « Est-ce la première fois ? » — la question et ses pièges.
@MainActor
@Suite("Marques « déjà vu »")
struct PersistenceStoreSeenTests {

    @Test("une marque jamais posée rend « pas encore vue »")
    func unknownKeyIsUnseen() async throws {
        let store = PersistenceStore.inMemory()

        let seen = try await store.hasBeenSeen("onboarding")
        #expect(seen == false)
    }

    @Test("poser la marque la rend vue")
    func settingMarksAsSeen() async throws {
        let store = PersistenceStore.inMemory()

        try await store.setHasBeenSeen(true, for: "onboarding")

        let seen = try await store.hasBeenSeen("onboarding")
        #expect(seen == true)
    }

    @Test("remettre la marque à false fait tout oublier")
    func resettingForgets() async throws {
        let store = PersistenceStore.inMemory()
        try await store.setHasBeenSeen(true, for: "onboarding")

        try await store.setHasBeenSeen(false, for: "onboarding")

        let seen = try await store.hasBeenSeen("onboarding")
        #expect(seen == false)
    }

    @Test("markAsSeen ne dit « première fois » qu'une seule fois")
    func markAsSeenIsTrueOnlyOnce() async throws {
        let store = PersistenceStore.inMemory()

        let first = try await store.markAsSeen("onboarding")
        let second = try await store.markAsSeen("onboarding")
        let third = try await store.markAsSeen("onboarding")

        #expect(first == true)
        #expect(second == false)
        #expect(third == false)
    }

    @Test("deux marquages concurrents ne comptent qu'une première fois")
    func concurrentMarkingYieldsASingleFirstTime() async throws {
        let store = PersistenceStore.inMemory()

        async let first = store.markAsSeen("onboarding")
        async let second = store.markAsSeen("onboarding")
        async let third = store.markAsSeen("onboarding")
        let outcomes = try await [first, second, third]

        #expect(outcomes.filter { $0 }.count == 1)
    }

    @Test("la marque survit à un store neuf sur le même support")
    func markSurvivesANewStore() async throws {
        let backend = InMemoryBackend()
        let store = PersistenceStore(repository: CodableRepository(backend: backend))
        try await store.markAsSeen("onboarding")

        let other = PersistenceStore(repository: CodableRepository(backend: backend))

        let seen = try await other.hasBeenSeen("onboarding")
        let firstTime = try await other.markAsSeen("onboarding")
        #expect(seen == true)
        #expect(firstTime == false)
    }

    @Test("une marque n'entre pas en collision avec une préférence du même nom")
    func seenKeysAreNamespaced() async throws {
        let store = PersistenceStore.inMemory()
        let preference = PersistenceKey<Bool>("onboarding", default: false)

        try await store.setHasBeenSeen(true, for: "onboarding")

        let preferenceValue = try await store.load(preference)
        let seen = try await store.hasBeenSeen("onboarding")
        #expect(preferenceValue == false)
        #expect(seen == true)
    }

    @Test("deux marques différentes sont indépendantes")
    func marksAreIndependent() async throws {
        let store = PersistenceStore.inMemory()

        try await store.setHasBeenSeen(true, for: "onboarding")

        let onboarding = try await store.hasBeenSeen("onboarding")
        let explainer = try await store.hasBeenSeen("cameraExplainer")
        #expect(onboarding == true)
        #expect(explainer == false)
    }

    @Test("la lecture en cache suit les écritures")
    func cachedReadFollowsWrites() async throws {
        let store = PersistenceStore.inMemory()
        #expect(store.hasBeenSeenCached("onboarding") == false)

        try await store.setHasBeenSeen(true, for: "onboarding")

        #expect(store.hasBeenSeenCached("onboarding") == true)
    }

    @Test("la lecture en cache ignore ce qui n'a pas été chargé")
    func cachedReadIgnoresUnloadedState() async throws {
        let backend = InMemoryBackend()
        let writer = PersistenceStore(repository: CodableRepository(backend: backend))
        try await writer.setHasBeenSeen(true, for: "onboarding")

        // Un store neuf : le support sait, le cache pas encore. C'est exactement le piège
        // que la doc de `hasBeenSeenCached(_:)` met en garde.
        let reader = PersistenceStore(repository: CodableRepository(backend: backend))
        #expect(reader.hasBeenSeenCached("onboarding") == false)

        let seen = try await reader.hasBeenSeen("onboarding")
        #expect(seen == true)
        #expect(reader.hasBeenSeenCached("onboarding") == true)
    }
}
