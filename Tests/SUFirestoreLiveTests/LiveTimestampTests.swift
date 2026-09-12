#if Firebase
import Foundation
import SUFirestore
import Testing

/// Le point où le double en mémoire et le vrai Firestore pourraient diverger sans qu'on
/// le voie : l'un encode les dates en JSON, l'autre en `Timestamp` à la nanoseconde.
///
/// Ces tests-là sont la seule preuve que les deux se comportent pareil.
@MainActor
@Suite("Émulateur — horodatages réels", .enabled(if: emulatorIsRequested), .serialized)
struct LiveTimestampTests {

    @Test("une date survit à l'aller-retour, fractions de seconde comprises")
    func subSecondPrecisionSurvivesRealFirestore() async throws {
        let store = makeBenchStore()
        let events = freshEvents()
        // Une date « sale » : ce que l'ISO 8601 aurait tronqué et qu'un Timestamp garde.
        let precise = Date(timeIntervalSince1970: 1_700_000_000.123_456)

        try await store.setDocument(Event(name: "précis", occurredAt: precise), id: "e1", in: events)

        let loaded = try await store.document("e1", in: events)
        let drift = abs((loaded?.occurredAt.timeIntervalSince1970 ?? 0) - precise.timeIntervalSince1970)
        #expect(drift < 0.001, "dérive de \(drift) s à travers un vrai Timestamp")
    }

    @Test("le serveur remplit lui-même un serverTimestamp")
    func serverFillsTheTimestamp() async throws {
        let store = makeBenchStore()
        let events = freshEvents()
        let before = Date.now
        try await store.setDocument(
            Event(name: "e", occurredAt: .now, recordedAt: nil),
            id: "e1", in: events
        )

        try await store.updateDocument(["recordedAt": .serverTimestamp], id: "e1", in: events)

        let loaded = try await store.document("e1", in: events, source: .server)
        let recorded = try #require(loaded?.recordedAt)
        // C'est bien une heure posée par le serveur, pas une valeur nulle ni une date de 1970.
        #expect(recorded >= before.addingTimeInterval(-60))
        #expect(recorded <= Date.now.addingTimeInterval(60))
    }

    @Test("un champ jamais écrit se relit en nil sans faire échouer le décodage")
    func absentDateDecodesAsNil() async throws {
        let store = makeBenchStore()
        let events = freshEvents()

        try await store.setDocument(
            Event(name: "e", occurredAt: .now, recordedAt: nil),
            id: "e1", in: events
        )

        // La fenêtre où un serverTimestamp n'est pas encore résolu ressemble à ça. Elle ne
        // doit pas faire échouer la lecture — d'où le `Date?` dans le modèle.
        let loaded = try await store.document("e1", in: events)
        #expect(loaded?.recordedAt == nil)
        #expect(loaded?.name == "e")
    }

    @Test("les dates se trient chronologiquement côté serveur")
    func datesSortChronologically() async throws {
        let store = makeBenchStore()
        let events = freshEvents()
        try await store.setDocument(Event(name: "b", occurredAt: Date(timeIntervalSince1970: 900_000_000)), id: "b", in: events)
        try await store.setDocument(Event(name: "a", occurredAt: Date(timeIntervalSince1970: 1_700_000_000)), id: "a", in: events)
        try await store.setDocument(Event(name: "c", occurredAt: Date(timeIntervalSince1970: 1_000_000_000)), id: "c", in: events)

        let chronological = try await store.documents(in: events) { $0.order(by: "occurredAt") }

        #expect(chronological.map(\.id) == ["b", "c", "a"])
    }

    @Test("un filtre sur une date compare bien des instants")
    func dateFiltering() async throws {
        let store = makeBenchStore()
        let events = freshEvents()
        let pivot = Date(timeIntervalSince1970: 1_000_000_000)
        try await store.setDocument(Event(name: "avant", occurredAt: pivot.addingTimeInterval(-100)), id: "avant", in: events)
        try await store.setDocument(Event(name: "après", occurredAt: pivot.addingTimeInterval(100)), id: "apres", in: events)

        let recent = try await store.documents(in: events) {
            $0.where("occurredAt", .isGreaterThan, .date(pivot))
        }

        #expect(recent.map(\.id) == ["apres"])
    }
}
#endif
