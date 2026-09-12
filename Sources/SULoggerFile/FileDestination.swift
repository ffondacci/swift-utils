#if FileLogging
import Foundation
import Synchronization
import SwiftyBeaver
import SULogger

/// Écrit les traces sur disque, avec rotation.
///
/// Elle sert à une chose que `OSLog` ne fait pas : **repartir avec le journal d'une
/// session**. Quand un utilisateur signale un problème, on veut le fichier, pas une
/// capture d'écran de la console.
///
/// ```swift
/// let file = try FileDestination()
/// Log.configure(LogConfiguration(destinations: [OSLogDestination(), file]))
/// ...
/// let urls = file.archivedFileURLs   // à joindre à un rapport de support
/// ```
///
/// > **Le handle est persistant.** La `FileDestination` d'origine de SwiftyBeaver rouvre
/// > et re-`stat` le fichier à chaque ligne — mesuré dans `UniLogger`, et corrigé là-bas
/// > de la même façon. Ici le descripteur reste ouvert et la taille est suivie en mémoire.
public final class FileDestination: LogDestination {

    /// Ce qui gouverne la rotation.
    public struct Rotation: Sendable, Equatable {

        /// Au-delà de cette taille, le fichier courant est archivé et un nouveau commence.
        public var maximumFileSize: Int

        /// Le nombre d'archives conservées. Au-delà, la plus ancienne est supprimée.
        ///
        /// Un journal qui grossit sans fin finit par remplir le disque de l'utilisateur —
        /// c'est une panne qu'on provoque soi-même.
        public var maximumArchivedFiles: Int

        public init(maximumFileSize: Int = 5 * 1_024 * 1_024, maximumArchivedFiles: Int = 3) {
            self.maximumFileSize = maximumFileSize
            self.maximumArchivedFiles = maximumArchivedFiles
        }

        public static let `default` = Rotation()
    }

    private let directory: URL
    private let fileName: String
    private let rotation: Rotation
    private let state: Mutex<State>

    private struct State {
        var handle: FileHandle?
        var size: Int = 0
    }

    /// - Parameters:
    ///   - directory: par défaut `Library/Logs` de l'app — l'emplacement prévu par Apple,
    ///     que le système n'efface pas comme il efface les caches.
    ///   - fileName: le nom du fichier courant.
    ///   - rotation: taille maximale et nombre d'archives.
    public init(
        directory: URL? = nil,
        fileName: String = "app.log",
        rotation: Rotation = .default
    ) throws {
        let resolved: URL
        if let directory {
            resolved = directory
        } else {
            resolved = try FileManager.default
                .url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "Logs", directoryHint: .isDirectory)
        }
        try FileManager.default.createDirectory(at: resolved, withIntermediateDirectories: true)

        self.directory = resolved
        self.fileName = fileName
        self.rotation = rotation
        self.state = Mutex(State())

        try openCurrentFile()
    }

    deinit {
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }
    }

    // MARK: - LogDestination

    public func write(_ entry: LogEntry) {
        append(entry.formatted)
    }

    /// Écrit une ligne déjà formatée. Utilisé par ``SwiftyBeaverBridge``.
    public func append(line: String) {
        append(line)
    }

    // MARK: - Fichiers

    /// Le fichier courant.
    public var currentFileURL: URL {
        directory.appending(path: fileName, directoryHint: .notDirectory)
    }

    /// Les archives, de la plus récente à la plus ancienne.
    public var archivedFileURLs: [URL] {
        (1...rotation.maximumArchivedFiles)
            .map { directory.appending(path: "\(fileName).\($0)", directoryHint: .notDirectory) }
            .filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Tous les fichiers du journal, courant en tête — ce qu'on joint à un rapport.
    public var allFileURLs: [URL] {
        [currentFileURL].filter { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
            + archivedFileURLs
    }

    /// La taille totale occupée sur le disque, en octets.
    public var totalSize: Int {
        allFileURLs.reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int) ?? 0)
        }
    }

    /// Efface tout le journal et recommence un fichier vide.
    public func reset() throws {
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
            state.size = 0
        }
        for url in allFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
        try openCurrentFile()
    }

    // MARK: - Écriture

    private func append(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

        // La rotation a lieu **avant** l'écriture, pas après. Deux raisons : la ligne la
        // plus récente est toujours dans le fichier courant — c'est ce qu'on cherche quand
        // on ouvre un journal — et aucun fichier ne dépasse jamais la taille annoncée.
        let wouldOverflow = state.withLock { state in
            state.handle != nil && state.size + data.count > rotation.maximumFileSize
        }
        if wouldOverflow { try? rotate() }

        state.withLock { state in
            guard let handle = state.handle else { return }
            // `write(contentsOf:)` peut jeter si le volume est plein : on ne fait pas
            // tomber l'app pour une ligne de journal.
            try? handle.write(contentsOf: data)
            state.size += data.count
        }
    }

    private func openCurrentFile() throws {
        let path = currentFileURL.path(percentEncoded: false)
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: currentFileURL)
        let size = try handle.seekToEnd()

        state.withLock { state in
            try? state.handle?.close()
            state.handle = handle
            state.size = Int(size)
        }
    }

    private func rotate() throws {
        state.withLock { state in
            try? state.handle?.close()
            state.handle = nil
        }

        let manager = FileManager.default
        // La plus ancienne disparaît, les autres reculent d'un cran.
        let oldest = directory.appending(path: "\(fileName).\(rotation.maximumArchivedFiles)")
        try? manager.removeItem(at: oldest)

        for index in stride(from: rotation.maximumArchivedFiles - 1, through: 1, by: -1) {
            let from = directory.appending(path: "\(fileName).\(index)")
            let to = directory.appending(path: "\(fileName).\(index + 1)")
            if manager.fileExists(atPath: from.path(percentEncoded: false)) {
                try? manager.moveItem(at: from, to: to)
            }
        }
        try? manager.moveItem(at: currentFileURL, to: directory.appending(path: "\(fileName).1"))

        try openCurrentFile()
    }
}

/// Branche cette destination sur un pipeline **SwiftyBeaver existant**.
///
/// `Log` n'en a pas besoin : il écrit directement dans ``FileDestination``. Ce pont sert
/// aux apps qui ont déjà du `SwiftyBeaver.debug(…)` ailleurs et veulent que ces lignes
/// finissent dans le même fichier.
///
/// ```swift
/// let file = try FileDestination()
/// SwiftyBeaver.addDestination(SwiftyBeaverBridge(writing: file))
/// ```
///
/// > Ce type n'est **pas** `Sendable`, et ne peut pas l'être : il hérite de
/// > `BaseDestination`, une classe que le SDK ne marque pas, et Swift 6 interdit à une
/// > classe `Sendable` d'hériter d'autre chose que `NSObject`. C'est donc à SwiftyBeaver
/// > d'en garantir l'usage, comme pour ses propres destinations.
public final class SwiftyBeaverBridge: BaseDestination {

    private let file: FileDestination

    public init(writing file: FileDestination) {
        self.file = file
        super.init()
    }

    public override func send(
        _ level: SwiftyBeaver.Level,
        msg: String,
        thread: String,
        file source: String,
        function: String,
        line: Int,
        context: Any? = nil
    ) -> String? {
        let formatted = super.send(
            level, msg: msg, thread: thread,
            file: source, function: function, line: line, context: context
        )
        if let formatted { file.append(line: formatted) }
        return formatted
    }
}
#endif
