import Foundation

/// D'où une lecture doit venir.
public enum ReadSource: Sendable, Hashable {

    /// Le cache s'il est frais, le serveur sinon. Le comportement de Firestore.
    case `default`

    /// Le serveur, toujours. Échoue hors ligne plutôt que de rendre une valeur périmée —
    /// à utiliser quand la fraîcheur prime sur la disponibilité.
    case server

    /// Le cache local uniquement. N'atteint jamais le réseau.
    case cache
}

/// Le réglage du client Firestore, à la volée.
///
/// Tout a une valeur par défaut : `FirestoreConfiguration()` convient à la plupart des
/// apps, et chaque réglage se change seul sans faire perdre les autres.
public struct FirestoreConfiguration: Sendable, Equatable {

    /// Garder une copie locale des documents lus, qui survit au lancement suivant.
    ///
    /// **Désactivé par défaut**, et c'est un choix. La persistance hors ligne est
    /// confortable, mais elle rend l'app capable de servir des données arbitrairement
    /// vieilles sans le dire, et elle écrit sur le disque de l'utilisateur. On l'active
    /// quand on en a besoin, pas par défaut.
    public var offlinePersistence: Bool

    /// La taille maximale du cache, en octets. `nil` laisse Firestore décider.
    ///
    /// Sans effet si ``offlinePersistence`` est `false`.
    public var cacheSizeBytes: Int64?

    /// D'où viennent les lectures qui ne précisent rien.
    public var defaultSource: ReadSource

    /// Pointer un émulateur local au lieu du vrai Firestore.
    ///
    /// ```swift
    /// FirestoreConfiguration(emulator: .init(host: "127.0.0.1", port: 8080))
    /// ```
    public var emulator: Emulator?

    public struct Emulator: Sendable, Equatable {
        public var host: String
        public var port: Int

        public init(host: String = "127.0.0.1", port: Int = 8080) {
            self.host = host
            self.port = port
        }
    }

    public init(
        offlinePersistence: Bool = false,
        cacheSizeBytes: Int64? = nil,
        defaultSource: ReadSource = .default,
        emulator: Emulator? = nil
    ) {
        self.offlinePersistence = offlinePersistence
        self.cacheSizeBytes = cacheSizeBytes
        self.defaultSource = defaultSource
        self.emulator = emulator
    }

    public static let `default` = FirestoreConfiguration()
}
