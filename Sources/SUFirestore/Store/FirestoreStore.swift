import Foundation
import Observation

/// Le point d'entrée du module, et la seule chose que l'app manipule au quotidien.
///
/// Il se place au-dessus du client et n'en expose rien. Sa signature ne mentionne ni
/// `Firestore`, ni `DocumentReference`, ni `QuerySnapshot` : brancher le vrai SDK ou le
/// double en mémoire ne change pas une ligne du code appelant.
///
/// ## Pourquoi pas de `shared`
///
/// Comme ``NetworkStore``, et pour la même raison : il lui faut un client configuré, et
/// le vrai client exige que `FirebaseApp.configure()` ait déjà eu lieu — ce que seule
/// l'app peut garantir. Un singleton planterait au premier appel.
///
/// ```swift
/// @main
/// struct LensyApp: App {
///     private let firestore: FirestoreStore
///
///     init() {
///         AppCheck.setAppCheckProviderFactory(MyFactory())   // AVANT
///         FirebaseApp.configure()                             // puis
///         firestore = FirestoreStore(client: LiveFirestore())
///     }
///
///     var body: some Scene {
///         WindowGroup { RootView() }.environment(firestore)
///     }
/// }
/// ```
@MainActor
@Observable
public final class FirestoreStore {

    @ObservationIgnored private let client: any FirestoreClient
    @ObservationIgnored private let defaultSource: ReadSource

    /// Le nombre d'opérations en cours. Observé : de quoi piloter un indicateur.
    public private(set) var inFlightCount = 0

    /// La dernière erreur rencontrée, hors annulations.
    ///
    /// Elle n'est pas effacée par une opération réussie — voir ``clearLastError()``.
    public private(set) var lastError: FirestoreError?

    /// Vrai dès qu'une opération est en cours.
    public var isLoading: Bool { inFlightCount > 0 }

    /// Construit un store sur un client quelconque, y compris un double de test.
    public init(client: any FirestoreClient, defaultSource: ReadSource = .default) {
        self.client = client
        self.defaultSource = defaultSource
    }

    /// Un store qui ne touche à rien, pour les previews SwiftUI et les tests.
    public static func inMemory() -> FirestoreStore {
        FirestoreStore(client: InMemoryFirestore())
    }

    // MARK: - Lecture

    /// Le document, ou `nil` s'il n'existe pas.
    ///
    /// Un document absent est une réponse, pas une erreur.
    public func document<Value: FirestoreValue>(
        at path: DocumentPath<Value>,
        source: ReadSource? = nil
    ) async throws(FirestoreError) -> Value? {
        try await snapshot(at: path, source: source)?.value
    }

    /// Le document **avec sa provenance** : cache ou serveur, écritures en attente ou non.
    ///
    /// C'est ce qui permet de dire la vérité à l'utilisateur plutôt que de présenter des
    /// données de la semaine dernière comme fraîches :
    ///
    /// ```swift
    /// if let snapshot = try await store.snapshot(at: .profiles.document("u1")),
    ///    snapshot.metadata.isFromCache {
    ///     banner = "Hors ligne — données du \(lastSync)"
    /// }
    /// ```
    public func snapshot<Value: FirestoreValue>(
        at path: DocumentPath<Value>,
        source: ReadSource? = nil
    ) async throws(FirestoreError) -> FirestoreDocument<Value>? {
        try await tracked { () async throws(FirestoreError) -> FirestoreDocument<Value>? in
            try await client.document(Value.self, at: path.path, source: source ?? defaultSource)
        }
    }

    /// Les documents d'une collection, filtrés et ordonnés.
    ///
    /// ```swift
    /// let actifs = try await store.documents(in: .profiles) {
    ///     $0.where("visits", .isGreaterThan, 10).order(by: "name").limit(to: 20)
    /// }
    /// ```
    public func documents<Value: FirestoreValue>(
        in path: CollectionPath<Value>,
        source: ReadSource? = nil,
        query build: (DocumentQuery) -> DocumentQuery = { $0 }
    ) async throws(FirestoreError) -> [FirestoreDocument<Value>] {
        try await query(in: path, source: source, query: build).documents
    }

    /// La même requête, **avec la provenance** du résultat.
    ///
    /// ```swift
    /// let result = try await store.query(in: .profiles) { $0.limit(to: 20) }
    /// if result.metadata.isFromCache { showOfflineBadge() }
    /// ```
    public func query<Value: FirestoreValue>(
        in path: CollectionPath<Value>,
        source: ReadSource? = nil,
        query build: (DocumentQuery) -> DocumentQuery = { $0 }
    ) async throws(FirestoreError) -> FirestoreQueryResult<Value> {
        let query = build(DocumentQuery())
        return try await tracked { () async throws(FirestoreError) -> FirestoreQueryResult<Value> in
            try await client.documents(
                Value.self,
                in: path.path,
                query: query,
                source: source ?? defaultSource
            )
        }
    }

    // MARK: - Écriture

    /// Écrit un document.
    ///
    /// - Parameter merge: `false` **remplace** le document — les champs absents de `value`
    ///   disparaissent. `true` ne touche qu'aux champs fournis. C'est la distinction qui
    ///   fait perdre des données quand on se trompe, d'où l'absence de valeur par défaut
    ///   implicite dans la documentation : `false` est le comportement de Firestore.
    public func setDocument<Value: FirestoreValue>(
        _ value: Value,
        at path: DocumentPath<Value>,
        merge: Bool = false
    ) async throws(FirestoreError) {
        try await tracked { () async throws(FirestoreError) in
            try await client.setDocument(value, at: path.path, merge: merge)
        }
    }

    /// Met à jour des champs d'un document **qui doit exister**.
    ///
    /// - Throws: ``FirestoreError/notFound(path:)`` si le document n'existe pas. Pour le
    ///   créer au besoin, utilisez ``setDocument(_:at:merge:)`` avec `merge: true`.
    public func updateDocument<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        at path: DocumentPath<Value>
    ) async throws(FirestoreError) {
        try await tracked { () async throws(FirestoreError) in
            try await client.updateDocument(fields, at: path.path)
        }
    }

    /// Supprime un document. Supprimer un document absent n'est pas une erreur.
    public func deleteDocument<Value: FirestoreValue>(
        at path: DocumentPath<Value>
    ) async throws(FirestoreError) {
        try await tracked { () async throws(FirestoreError) in
            try await client.deleteDocument(at: path.path)
        }
    }

    /// Applique plusieurs écritures d'un seul coup, de façon atomique.
    ///
    /// ```swift
    /// try await store.batch { batch in
    ///     batch.set(profile, at: .profiles.document(profile.id), merge: true)
    ///     batch.delete(at: .drafts.document(draftID))
    /// }
    /// ```
    ///
    /// - Throws: ``FirestoreError/invalidArgument(path:reason:)`` si le lot dépasse les
    ///   500 écritures que Firestore accepte.
    public func batch(_ build: (inout DocumentBatch) -> Void) async throws(FirestoreError) {
        var batch = DocumentBatch()
        build(&batch)

        guard !batch.operations.isEmpty else { return }
        guard !batch.exceedsLimit else {
            throw .invalidArgument(
                path: batch.operations.first?.path ?? "",
                reason: "\(batch.operations.count) écritures dans un lot, maximum \(DocumentBatch.maximumOperations)"
            )
        }

        let operations = batch.operations
        try await tracked { () async throws(FirestoreError) in
            try await client.commit(operations)
        }
    }

    // MARK: - La même chose, par collection et identifiant

    /// Les quatre opérations ci-dessus, désignées par `id` **dans** une collection.
    ///
    /// C'est la forme courante, et la seule où la syntaxe à point implicite fonctionne :
    /// `.profiles` se résout contre le type attendu, qui est bien `CollectionPath` ici.
    ///
    /// ```swift
    /// try await store.setDocument(profile, id: "u1", in: .profiles)
    /// ```
    ///
    /// Gardez les formes `at:` quand vous tenez déjà un chemin — une sous-collection,
    /// ou un document transporté d'un écran à l'autre.
    public func document<Value: FirestoreValue>(
        _ id: String,
        in collection: CollectionPath<Value>,
        source: ReadSource? = nil
    ) async throws(FirestoreError) -> Value? {
        try await document(at: collection.document(id), source: source)
    }

    /// Le document avec sa provenance, désigné par `id` dans une collection.
    public func snapshot<Value: FirestoreValue>(
        _ id: String,
        in collection: CollectionPath<Value>,
        source: ReadSource? = nil
    ) async throws(FirestoreError) -> FirestoreDocument<Value>? {
        try await snapshot(at: collection.document(id), source: source)
    }

    public func setDocument<Value: FirestoreValue>(
        _ value: Value,
        id: String,
        in collection: CollectionPath<Value>,
        merge: Bool = false
    ) async throws(FirestoreError) {
        try await setDocument(value, at: collection.document(id), merge: merge)
    }

    public func updateDocument<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        id: String,
        in collection: CollectionPath<Value>
    ) async throws(FirestoreError) {
        try await updateDocument(fields, at: collection.document(id))
    }

    public func deleteDocument<Value: FirestoreValue>(
        id: String,
        in collection: CollectionPath<Value>
    ) async throws(FirestoreError) {
        try await deleteDocument(at: collection.document(id))
    }

    /// Lire, décider, écrire — sans qu'un autre client s'intercale.
    ///
    /// Un lot écrit sans lire ; une transaction lit d'abord et décide ensuite. C'est ce
    /// qu'il faut dès que la nouvelle valeur dépend de l'ancienne autrement que par un
    /// simple incrément.
    ///
    /// ```swift
    /// try await store.transaction { transaction in
    ///     let compte = try transaction.document("c1", in: .comptes)
    ///     guard let compte, compte.solde >= montant else {
    ///         // Le corps n'est pas typé, donc le type est nommé ici — ou jetez
    ///         // simplement votre propre erreur métier.
    ///         throw FirestoreError.transactionCancelled(reason: "solde insuffisant")
    ///     }
    ///     transaction.set(compte.débité(de: montant), id: "c1", in: .comptes)
    /// }
    /// ```
    ///
    /// Le corps peut jeter **n'importe quelle** erreur pour abandonner : ce qui n'est pas
    /// une ``FirestoreError`` devient une
    /// ``FirestoreError/transactionCancelled(reason:)``. Vos erreurs métier passent donc
    /// telles quelles, sans emprunter un cas qui ne leur correspond pas.
    ///
    /// - Important: toutes les lectures doivent précéder toutes les écritures, et le corps
    ///   peut être **rejoué** en cas de conflit — n'y mettez aucun effet de bord.
    public func transaction(
        _ body: @Sendable @escaping (any TransactionContext) throws -> Void
    ) async throws(FirestoreError) {
        try await tracked { () async throws(FirestoreError) in
            try await client.runTransaction(body)
        }
    }

    /// Oublie la dernière erreur, une fois qu'elle a été montrée.
    public func clearLastError() {
        lastError = nil
    }

    // MARK: - Suivi

    /// Compte l'opération et retient son erreur.
    ///
    /// Les appelants annotent le type d'erreur de leur closure — sans ça, Swift 6.3
    /// l'infère en `any Error` malgré le type du paramètre, et refuse la conversion.
    private func tracked<T>(
        _ operation: () async throws(FirestoreError) -> T
    ) async throws(FirestoreError) -> T {
        inFlightCount += 1
        defer { inFlightCount -= 1 }

        do {
            return try await operation()
        } catch {
            if error != .cancelled { lastError = error }
            throw error
        }
    }
}
