import Foundation
import Testing
@testable import SUFirestore

/// Les dates sont le piège classique de Firestore en Swift : le SDK stocke des
/// `Timestamp` à la nanoseconde, Swift manipule des `Date`, et un horodatage serveur vaut
/// `null` tant que le serveur n'a pas répondu.
@MainActor
@Suite("Horodatages")
struct TimestampTests {

    struct Event: Codable, Sendable, Equatable {
        var name: String
        var occurredAt: Date
        /// Optionnel **exprès** : un `serverTimestamp` vaut `null` entre l'écriture locale
        /// et la réponse du serveur.
        var recordedAt: Date?
    }

    static let events = CollectionPath<Event>("events")

    @Test("une date survit à l'aller-retour, fractions de seconde comprises")
    func subSecondPrecisionSurvives() async throws {
        let (store, _) = makeStore()
        // Une date « sale » : c'est exactement ce qu'ISO 8601 aurait tronqué.
        let precise = Date(timeIntervalSince1970: 1_700_000_000.123_456)
        let event = Event(name: "précis", occurredAt: precise)

        try await store.setDocument(event, id: "e1", in: Self.events)

        let loaded = try await store.document("e1", in: Self.events)
        let drift = abs((loaded?.occurredAt.timeIntervalSince1970 ?? 0) - precise.timeIntervalSince1970)
        #expect(drift < 0.000_01, "dérive de \(drift) s")
    }

    @Test("les dates se trient dans l'ordre chronologique, pas alphabétique")
    func datesSortChronologically() async throws {
        let (store, _) = makeStore()
        // Trois dates dont la représentation textuelle ne suit pas l'ordre chronologique
        // de façon évidente — le piège d'un tri sur chaîne.
        try await store.setDocument(
            Event(name: "b", occurredAt: Date(timeIntervalSince1970: 900_000_000)),
            id: "b", in: Self.events
        )
        try await store.setDocument(
            Event(name: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000)),
            id: "a", in: Self.events
        )
        try await store.setDocument(
            Event(name: "c", occurredAt: Date(timeIntervalSince1970: 1_000_000_000)),
            id: "c", in: Self.events
        )

        let chronological = try await store.documents(in: Self.events) { $0.order(by: "occurredAt") }

        #expect(chronological.map(\.id) == ["b", "c", "a"])
    }

    @Test("un filtre sur une date compare bien des instants")
    func dateFiltering() async throws {
        let (store, _) = makeStore()
        let pivot = Date(timeIntervalSince1970: 1_000_000_000)
        try await store.setDocument(Event(name: "avant", occurredAt: pivot.addingTimeInterval(-100)), id: "avant", in: Self.events)
        try await store.setDocument(Event(name: "après", occurredAt: pivot.addingTimeInterval(100)), id: "apres", in: Self.events)

        let recent = try await store.documents(in: Self.events) {
            $0.where("occurredAt", .isGreaterThan, .date(pivot))
        }

        #expect(recent.map(\.id) == ["apres"])
    }

    @Test("un horodatage serveur remplit bien le champ")
    func serverTimestampFillsTheField() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(
            Event(name: "e", occurredAt: .now, recordedAt: nil),
            id: "e1", in: Self.events
        )

        try await store.updateDocument(["recordedAt": .serverTimestamp], id: "e1", in: Self.events)

        let loaded = try await store.document("e1", in: Self.events)
        #expect(loaded?.recordedAt != nil)
    }

    @Test("un champ absent se relit en nil sans faire échouer le décodage")
    func pendingServerTimestampDecodesAsNil() async throws {
        let (store, _) = makeStore()

        try await store.setDocument(
            Event(name: "e", occurredAt: .now, recordedAt: nil),
            id: "e1", in: Self.events
        )

        // C'est la fenêtre entre l'écriture locale et la réponse du serveur. Elle ne doit
        // pas faire échouer la lecture — d'où le `Date?` dans le modèle.
        let loaded = try await store.document("e1", in: Self.events)
        #expect(loaded?.recordedAt == nil)
        #expect(loaded?.name == "e")
    }

    @Test("supprimer un champ le retire, au lieu de le mettre à nul")
    func deleteFieldRemovesIt() async throws {
        let (store, client) = makeStore()
        try await store.setDocument(
            Event(name: "e", occurredAt: .now, recordedAt: .now),
            id: "e1", in: Self.events
        )

        try await store.updateDocument(["recordedAt": .deleteField], id: "e1", in: Self.events)

        let loaded = try await store.document("e1", in: Self.events)
        #expect(loaded?.recordedAt == nil)

        // La distinction compte : un champ absent ne remonte pas dans une requête
        // d'égalité sur nul, un champ nul si.
        let raw = await client.storedPaths
        #expect(raw == ["events/e1"])
    }

    @Test("un horodatage serveur passe aussi dans un lot")
    func serverTimestampInBatch() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(Event(name: "e", occurredAt: .now), id: "e1", in: Self.events)

        try await store.batch { batch in
            batch.update(["recordedAt": .serverTimestamp], id: "e1", in: Self.events)
        }

        let loaded = try await store.document("e1", in: Self.events)
        #expect(loaded?.recordedAt != nil)
    }
}
