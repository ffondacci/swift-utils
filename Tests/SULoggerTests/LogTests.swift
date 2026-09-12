import Foundation
import Synchronization
import Testing
@testable import SULogger

/// Note tout ce qu'on lui envoie.
final class SpyDestination: LogDestination {
    private let storage = Mutex<[LogEntry]>([])

    func write(_ entry: LogEntry) { storage.withLock { $0.append(entry) } }

    var entries: [LogEntry] { storage.withLock { $0 } }
    var messages: [String] { entries.map(\.message) }
}

/// Compte combien de fois un message a été **construit**.
///
/// C'est la mesure qui compte pour un logger : un `Log.debug("\(gros.description)")` filtré
/// en production ne doit rien coûter du tout.
final class MessageCounter: Sendable {
    private let count = Mutex(0)

    func build() -> String {
        count.withLock { $0 += 1 }
        return "message"
    }

    var buildCount: Int { count.withLock { $0 } }
}

/// `Log` porte un état global : les tests s'exécutent en série pour ne pas se marcher
/// dessus, et chacun repose la configuration.
@Suite("Journal", .serialized)
struct LogTests {

    private func withSpy(
        minimumLevel: LogLevel = .debug,
        categories: Set<LogCategory> = Set(LogCategory.allCases),
        _ body: (SpyDestination) -> Void
    ) {
        let spy = SpyDestination()
        Log.configure(LogConfiguration(
            minimumLevel: minimumLevel,
            categories: categories,
            destinations: [spy]
        ))
        body(spy)
        Log.configure(.silent)
    }

    @Test("une trace atteint la destination avec son niveau et sa catégorie")
    func writesThrough() {
        withSpy { spy in
            Log.error("échec", category: .network)

            #expect(spy.entries.count == 1)
            #expect(spy.entries.first?.level == .error)
            #expect(spy.entries.first?.category == .network)
            #expect(spy.entries.first?.message == "échec")
        }
    }

    @Test("la catégorie par défaut est app")
    func defaultCategory() {
        withSpy { spy in
            Log.info("démarrage")
            #expect(spy.entries.first?.category == .app)
        }
    }

    @Test("le seuil de niveau écarte ce qui est en dessous")
    func levelThreshold() {
        withSpy(minimumLevel: .warning) { spy in
            Log.debug("d")
            Log.info("i")
            Log.warning("w")
            Log.error("e")
            Log.fault("f")

            #expect(spy.messages == ["w", "e", "f"])
        }
    }

    @Test("une catégorie retirée disparaît entièrement")
    func categoryFilter() {
        withSpy(categories: [.network]) { spy in
            Log.info("réseau", category: .network)
            Log.info("appli", category: .app)
            Log.info("stockage", category: .persistence)

            #expect(spy.messages == ["réseau"])
        }
    }

    @Test("un message filtré n'est même pas construit")
    func filteredMessageIsNeverBuilt() {
        let counter = MessageCounter()

        withSpy(minimumLevel: .error) { _ in
            Log.debug(counter.build())
            Log.info(counter.build())
            #expect(counter.buildCount == 0, "l'autoclosure n'a pas été évaluée")

            Log.error(counter.build())
            #expect(counter.buildCount == 1)
        }
    }

    @Test("un message d'une catégorie écartée n'est pas construit non plus")
    func filteredCategoryMessageIsNeverBuilt() {
        let counter = MessageCounter()

        withSpy(categories: [.network]) { _ in
            Log.info(counter.build(), category: .app)
            #expect(counter.buildCount == 0)
        }
    }

    @Test("sans destination, écrire ne coûte rien")
    func silentConfigurationBuildsNothing() {
        let counter = MessageCounter()
        Log.configure(.silent)

        Log.error(counter.build())

        #expect(counter.buildCount == 0)
    }

    @Test("plusieurs destinations reçoivent toutes la même trace")
    func multipleDestinations() {
        let first = SpyDestination()
        let second = SpyDestination()
        Log.configure(LogConfiguration(destinations: [first, second]))

        Log.info("partagée")

        #expect(first.messages == ["partagée"])
        #expect(second.messages == ["partagée"])
        Log.configure(.silent)
    }

    @Test("ajouter une destination ne retire pas les autres")
    func addKeepsExisting() {
        let first = SpyDestination()
        let second = SpyDestination()
        Log.configure(LogConfiguration(destinations: [first]))

        Log.add(second)
        Log.info("après ajout")

        #expect(first.messages == ["après ajout"])
        #expect(second.messages == ["après ajout"])
        Log.configure(.silent)
    }

    @Test("la trace porte le fichier et la ligne d'appel, pas ceux du logger")
    func capturesCallSite() {
        withSpy { spy in
            Log.info("ici")

            #expect(spy.entries.first?.file == "LogTests.swift")
            #expect(spy.entries.first?.line ?? 0 > 0)
        }
    }

    @Test("la ligne formatée porte l'horodatage, le niveau, la catégorie et l'origine")
    func formatting() {
        let entry = LogEntry(
            level: .warning,
            category: .persistence,
            message: "cache périmé",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.123),
            file: "SUPersistence/Store.swift",
            function: "load()",
            line: 42
        )

        let line = entry.formatted
        #expect(line.contains("2023-11-14"))
        // Pas une valeur exacte : `Date(timeIntervalSince1970:)` arrondit en Double.
        // Ce qui compte est la présence de trois décimales.
        #expect(
            line.range(of: #"\.\d{3}Z"#, options: .regularExpression) != nil,
            "les millisecondes servent à recoller deux journaux — reçu « \(line) »"
        )
        #expect(line.contains("[persistence]"))
        #expect(line.contains("Store.swift:42"))
        #expect(line.contains("cache périmé"))
        #expect(line.contains("SUPersistence/") == false, "seul le nom du fichier est gardé")
    }

    @Test("les niveaux s'ordonnent du plus bavard au plus grave")
    func levelOrdering() {
        #expect(LogLevel.debug < .info)
        #expect(LogLevel.info < .warning)
        #expect(LogLevel.warning < .error)
        #expect(LogLevel.error < .fault)
    }
}
