import Foundation
@testable import SULogger
import Testing

/// Ce que `OSLog` ne fait pas : repartir avec le journal d'une session.
@Suite("Journal fichier")
struct FileDestinationTests {

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "su-logger-tests", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private func contents(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func entry(_ message: String) -> LogEntry {
        LogEntry(level: .info, category: .app, message: message)
    }

    @Test("une trace atterrit dans le fichier")
    func writesToFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(directory: directory)

        destination.write(entry("première ligne"))

        #expect(contents(of: destination.currentFileURL).contains("première ligne"))
    }

    @Test("les traces s'accumulent au lieu de s'écraser")
    func appends() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(directory: directory)

        destination.write(entry("une"))
        destination.write(entry("deux"))
        destination.write(entry("trois"))

        let lines = contents(of: destination.currentFileURL)
            .split(separator: "\n")
        #expect(lines.count == 3)
    }

    @Test("une destination rouverte reprend le fichier sans l'écraser")
    func reopeningKeepsHistory() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try FileDestination(directory: directory)
        first.write(entry("session précédente"))

        let second = try FileDestination(directory: directory)
        second.write(entry("session courante"))

        let text = contents(of: second.currentFileURL)
        #expect(text.contains("session précédente"))
        #expect(text.contains("session courante"))
    }

    @Test("le fichier tourne quand il dépasse la taille maximale")
    func rotatesWhenTooLarge() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(
            directory: directory,
            rotation: .init(maximumFileSize: 200, maximumArchivedFiles: 3)
        )

        for index in 0..<20 {
            destination.write(entry("ligne de remplissage numéro \(index)"))
        }

        #expect(destination.archivedFileURLs.isEmpty == false, "au moins une archive")
        #expect(contents(of: destination.currentFileURL).contains("numéro 19"))
    }

    @Test("le nombre d'archives est plafonné")
    func archivesAreCapped() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(
            directory: directory,
            rotation: .init(maximumFileSize: 120, maximumArchivedFiles: 2)
        )

        for index in 0..<60 {
            destination.write(entry("remplissage \(index)"))
        }

        // Un journal qui grossit sans fin remplit le disque de l'utilisateur.
        #expect(destination.archivedFileURLs.count <= 2)
        #expect(destination.allFileURLs.count <= 3)
    }

    @Test("écrire continue de fonctionner après une rotation")
    func writingSurvivesRotation() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(
            directory: directory,
            rotation: .init(maximumFileSize: 150, maximumArchivedFiles: 2)
        )

        for index in 0..<30 { destination.write(entry("avant \(index)")) }
        destination.write(entry("après la rotation"))

        #expect(contents(of: destination.currentFileURL).contains("après la rotation"))
    }

    @Test("la taille totale reflète ce qui est sur le disque")
    func totalSizeIsReported() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(directory: directory)

        #expect(destination.totalSize == 0)
        destination.write(entry("quelque chose"))
        #expect(destination.totalSize > 0)
    }

    @Test("reset efface tout et repart d'un fichier vide")
    func resetClearsEverything() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(
            directory: directory,
            rotation: .init(maximumFileSize: 120, maximumArchivedFiles: 2)
        )
        for index in 0..<40 { destination.write(entry("remplissage \(index)")) }

        try destination.reset()

        #expect(destination.archivedFileURLs.isEmpty)
        #expect(contents(of: destination.currentFileURL).isEmpty)

        destination.write(entry("après reset"))
        #expect(contents(of: destination.currentFileURL).contains("après reset"))
    }

    @Test("branchée sur Log, elle reçoit les traces de l'app")
    func worksAsALogDestination() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = try FileDestination(directory: directory)

        await Log.withConfiguration(LogConfiguration(destinations: [destination])) {
            Log.error("échec réseau", category: .network)
        }

        let text = contents(of: destination.currentFileURL)
        #expect(text.contains("échec réseau"))
        #expect(text.contains("[network]"))
    }
}
