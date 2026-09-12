import Foundation
import Synchronization

/// Garde les traces en mémoire, pour les affirmer dans un test.
///
/// Publique parce qu'elle sert autant aux tests du dépôt qu'à ceux d'une app : vérifier
/// qu'un échec a bien été tracé est un test légitime, et il ne devrait pas obliger chacun
/// à réécrire ce type.
public final class CollectingDestination: LogDestination {

    private let storage = Mutex<[LogEntry]>([])

    public init() {}

    public func write(_ entry: LogEntry) {
        storage.withLock { $0.append(entry) }
    }

    /// Tout ce qui a été tracé, dans l'ordre.
    public var entries: [LogEntry] { storage.withLock { $0 } }

    /// Les traces d'une catégorie.
    public func entries(for category: LogCategory) -> [LogEntry] {
        entries.filter { $0.category == category }
    }

    /// Les traces d'au moins ce niveau.
    public func entries(atLeast level: LogLevel) -> [LogEntry] {
        entries.filter { $0.level >= level }
    }

    /// Vrai si une trace contient ce fragment.
    public func contains(_ fragment: String) -> Bool {
        entries.contains { $0.message.contains(fragment) }
    }

    public func clear() {
        storage.withLock { $0.removeAll() }
    }
}
