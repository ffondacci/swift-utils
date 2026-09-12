import Foundation

/// Une valeur et la date à laquelle elle a été écrite.
///
/// C'est ce qui permet de répondre à « est-ce encore frais ? » sans tenir un registre à
/// côté. Toute valeur persistée est emballée ainsi ; l'API courante déballe pour vous, et
/// ``PersistenceStore/stored(_:)`` donne accès à l'enveloppe quand la date compte.
///
/// ```swift
/// if let entry = try await store.stored(.catalog), !entry.isStale(after: .seconds(3600)) {
///     return entry.value          // assez frais, on garde
/// }
/// return try await network.send(FetchCatalog())   // périmé, on rafraîchit
/// ```
public struct StoredValue<Value: PersistentValue>: PersistentValue {

    /// La valeur elle-même.
    public let value: Value

    /// Le moment de l'écriture.
    public let storedAt: Date

    public init(value: Value, storedAt: Date = .now) {
        self.value = value
        self.storedAt = storedAt
    }

    /// Le temps écoulé depuis l'écriture.
    public var age: Duration {
        .seconds(Date.now.timeIntervalSince(storedAt))
    }

    /// Indique si la valeur a dépassé la durée de fraîcheur donnée.
    ///
    /// Une horloge qui recule — changement de fuseau, synchronisation NTP — peut rendre
    /// un âge négatif. Le cas est traité comme « encore frais » plutôt que de faire
    /// invalider tout un cache par une correction d'heure.
    public func isStale(after duration: Duration) -> Bool {
        age > duration
    }
}

extension StoredValue: Equatable where Value: Equatable {}
