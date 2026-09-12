import Foundation

/// Ce que Firestore sait d'une lecture, au-delà de son contenu.
///
/// C'est ce qui permet à une app de dire la vérité à l'utilisateur : « ces données datent
/// de votre dernière connexion » plutôt que de les présenter comme fraîches.
public struct FirestoreMetadata: Sendable, Equatable {

    /// La donnée vient du **cache local**, pas du serveur.
    ///
    /// Vrai hors ligne, et vrai pendant le court instant où Firestore sert le cache en
    /// attendant la réponse du serveur.
    public let isFromCache: Bool

    /// Des écritures locales ne sont **pas encore confirmées** par le serveur.
    ///
    /// La valeur lue les inclut déjà — Firestore applique les écritures localement avant
    /// de les envoyer. Ce qu'elle signale, c'est qu'elles peuvent encore échouer.
    public let hasPendingWrites: Bool

    public init(isFromCache: Bool, hasPendingWrites: Bool) {
        self.isFromCache = isFromCache
        self.hasPendingWrites = hasPendingWrites
    }

    /// Confirmée par le serveur, sans écriture en attente.
    public var isFresh: Bool { !isFromCache && !hasPendingWrites }

    /// Ce que rend un magasin qui n'a pas de notion de cache — le double en mémoire.
    public static let synchronized = FirestoreMetadata(isFromCache: false, hasPendingWrites: false)
}

/// Le résultat d'une requête : les documents, et ce que Firestore sait de la lecture.
public struct FirestoreQueryResult<Value: FirestoreValue>: Sendable {

    /// Les documents, dans l'ordre demandé.
    public let documents: [FirestoreDocument<Value>]

    /// La provenance de la lecture, pour l'ensemble du résultat.
    public let metadata: FirestoreMetadata

    public init(documents: [FirestoreDocument<Value>], metadata: FirestoreMetadata) {
        self.documents = documents
        self.metadata = metadata
    }

    /// Les valeurs seules, quand la provenance n'intéresse pas.
    public var values: [Value] { documents.map(\.value) }

    public var isEmpty: Bool { documents.isEmpty }
    public var count: Int { documents.count }
}

extension FirestoreQueryResult: Equatable where Value: Equatable {}
