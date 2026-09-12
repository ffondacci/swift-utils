#if Firebase
import Foundation
import FirebaseFirestore
import SUFirestore

/// L'adaptateur qui parle au vrai Firestore.
///
/// C'est le **seul** type du dépôt qui importe `FirebaseFirestore`, et il ne franchit
/// jamais la frontière : aucun `DocumentReference`, aucun `QuerySnapshot` n'apparaît dans
/// sa surface publique. Le store, au-dessus, ne voit que ``FirestoreClient``.
///
/// > Important : `FirebaseApp.configure()` doit avoir eu lieu **avant** de construire ce
/// > client, et App Check doit être installé avant `configure()`. Ce module ne configure
/// > rien — Firebase exige que `configure()` soit appelé exactement une fois, et seule
/// > l'app peut le garantir.
///
/// ```swift
/// init() {
///     AppCheck.setAppCheckProviderFactory(MyFactory())
///     FirebaseApp.configure()
///     store = FirestoreStore(client: LiveFirestore())
/// }
/// ```
public struct LiveFirestore: FirestoreClient {

    // `Firestore` n'est pas annoté `Sendable` — le SDK compile en mode Swift 5 — mais
    // Firebase le documente explicitement comme utilisable depuis n'importe quel thread.
    // L'annotation est donc une promesse que le SDK tient, pas une que nous faisons.
    // Garder ce type en `struct` nonisolated plutôt qu'en acteur évite en prime que les
    // snapshots du SDK aient à franchir une frontière d'isolation.
    nonisolated(unsafe) private let database: Firestore

    /// - Parameter configuration: appliquée à l'instance au moment de la construction.
    ///   Les réglages de Firestore doivent être posés **avant** le premier accès aux
    ///   données ; construire ce client tôt, une seule fois, est donc la bonne pratique.
    public init(configuration: FirestoreConfiguration = .default) {
        let database = Firestore.firestore()

        let settings = database.settings
        if configuration.offlinePersistence {
            settings.cacheSettings = configuration.cacheSizeBytes.map {
                PersistentCacheSettings(sizeBytes: NSNumber(value: $0))
            } ?? PersistentCacheSettings()
        } else {
            settings.cacheSettings = MemoryCacheSettings()
        }

        if let emulator = configuration.emulator {
            settings.host = "\(emulator.host):\(emulator.port)"
            settings.isSSLEnabled = false
        }
        database.settings = settings

        self.database = database
    }

    // MARK: - Lecture

    public func document<Value: FirestoreValue>(
        _ type: Value.Type,
        at path: String,
        source: ReadSource
    ) async throws(FirestoreError) -> FirestoreDocument<Value>? {
        do {
            let snapshot = try await database.document(path).getDocument(source: source.firestoreSource)
            guard snapshot.exists else { return nil }
            do {
                return FirestoreDocument(
                    id: snapshot.documentID,
                    value: try snapshot.data(as: Value.self),
                    metadata: FirestoreMetadata(snapshot.metadata)
                )
            } catch {
                throw FirestoreError.decodingFailed(path: path, type: "\(Value.self)", reason: "\(error)")
            }
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    public func documents<Value: FirestoreValue>(
        _ type: Value.Type,
        in path: String,
        query: DocumentQuery,
        source: ReadSource
    ) async throws(FirestoreError) -> FirestoreQueryResult<Value> {
        do {
            let snapshot = try await Self.build(query, on: database.collection(path))
                .getDocuments(source: source.firestoreSource)

            let documents = try snapshot.documents.map { document in
                do {
                    return FirestoreDocument(
                        id: document.documentID,
                        value: try document.data(as: Value.self),
                        metadata: FirestoreMetadata(document.metadata)
                    )
                } catch {
                    throw FirestoreError.decodingFailed(
                        path: "\(path)/\(document.documentID)",
                        type: "\(Value.self)",
                        reason: "\(error)"
                    )
                }
            }
            return FirestoreQueryResult(
                documents: documents,
                metadata: FirestoreMetadata(snapshot.metadata)
            )
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    // MARK: - Écriture

    public func setDocument<Value: FirestoreValue>(
        _ value: Value,
        at path: String,
        merge: Bool
    ) async throws(FirestoreError) {
        let fields = try Self.encode(value, at: path)
        do {
            try await database.document(path).setData(fields, merge: merge)
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    public func updateDocument(
        _ fields: [String: DocumentField],
        at path: String
    ) async throws(FirestoreError) {
        do {
            try await database.document(path).updateData(Self.firestoreFields(fields))
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    public func deleteDocument(at path: String) async throws(FirestoreError) {
        do {
            try await database.document(path).delete()
        } catch {
            throw Self.translate(error, path: path)
        }
    }

    public func commit(_ operations: [DocumentWrite]) async throws(FirestoreError) {
        let batch = database.batch()

        for operation in operations {
            switch operation {
            case let .set(path, value, merge):
                batch.setData(try Self.encode(value, at: path), forDocument: database.document(path), merge: merge)
            case let .update(path, fields):
                batch.updateData(Self.firestoreFields(fields), forDocument: database.document(path))
            case let .delete(path):
                batch.deleteDocument(database.document(path))
            }
        }

        do {
            try await batch.commit()
        } catch {
            throw Self.translate(error, path: operations.first?.path)
        }
    }

    // MARK: - Transactions

    public func runTransaction(
        _ body: @Sendable @escaping (any TransactionContext) throws -> Void
    ) async throws(FirestoreError) {
        do {
            _ = try await database.runTransaction { transaction, errorPointer in
                do {
                    try body(LiveTransaction(transaction: transaction, database: database))
                    return nil
                } catch let error as FirestoreError {
                    errorPointer?.pointee = error as NSError
                    return nil
                } catch {
                    // Firestore n'accepte pas qu'on jette depuis le corps : on lui passe
                    // l'erreur par le pointeur, et il nous la rendra.
                    errorPointer?.pointee = FirestoreError
                        .transactionCancelled(reason: "\(error)") as NSError
                    return nil
                }
            }
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw Self.translate(error, path: nil)
        }
    }

    // MARK: - Conversions

    static func encode<Value: FirestoreValue>(
        _ value: Value,
        at path: String
    ) throws(FirestoreError) -> [String: Any] {
        do {
            return try Firestore.Encoder().encode(value)
        } catch {
            throw .encodingFailed(path: path, type: "\(Value.self)", reason: "\(error)")
        }
    }

    static func firestoreFields(_ fields: [String: DocumentField]) -> [String: Any] {
        fields.mapValues(firestoreField(of:))
    }

    private static func firestoreField(of field: DocumentField) -> Any {
        switch field {
        case let .string(text): text
        case let .int(number): number
        case let .double(number): number
        case let .bool(flag): flag
        case let .date(date): Timestamp(date: date)
        case let .array(values): values.map(firestoreField(of:))
        case .serverTimestamp: FieldValue.serverTimestamp()
        case .deleteField: FieldValue.delete()
        case let .increment(amount): FieldValue.increment(amount)
        case let .arrayUnion(values): FieldValue.arrayUnion(values.map(firestoreField(of:)))
        case let .arrayRemove(values): FieldValue.arrayRemove(values.map(firestoreField(of:)))
        case .null: NSNull()
        }
    }

    private static func firestoreValue(of value: QueryValue) -> Any {
        switch value {
        case let .string(text): text
        case let .int(number): number
        case let .double(number): number
        case let .bool(flag): flag
        case let .date(date): Timestamp(date: date)
        case let .array(values): values.map(firestoreValue(of:))
        case .null: NSNull()
        }
    }

    private static func build(_ query: DocumentQuery, on collection: CollectionReference) -> Query {
        var result: Query = collection

        for filter in query.filters {
            let value = firestoreValue(of: filter.value)
            result = switch filter.comparison {
            case .isEqualTo: result.whereField(filter.field, isEqualTo: value)
            case .isNotEqualTo: result.whereField(filter.field, isNotEqualTo: value)
            case .isLessThan: result.whereField(filter.field, isLessThan: value)
            case .isLessThanOrEqualTo: result.whereField(filter.field, isLessThanOrEqualTo: value)
            case .isGreaterThan: result.whereField(filter.field, isGreaterThan: value)
            case .isGreaterThanOrEqualTo: result.whereField(filter.field, isGreaterThanOrEqualTo: value)
            case .arrayContains: result.whereField(filter.field, arrayContains: value)
            case .arrayContainsAny: result.whereField(filter.field, arrayContainsAny: value as? [Any] ?? [])
            case .isIn: result.whereField(filter.field, in: value as? [Any] ?? [])
            case .isNotIn: result.whereField(filter.field, notIn: value as? [Any] ?? [])
            }
        }
        for ordering in query.orderings {
            result = result.order(by: ordering.field, descending: ordering.descending)
        }
        if let cursor = query.start {
            let values = cursor.values.map(firestoreValue(of:))
            result = cursor.bound == .startAt ? result.start(at: values) : result.start(after: values)
        }
        if let cursor = query.end {
            let values = cursor.values.map(firestoreValue(of:))
            result = cursor.bound == .endAt ? result.end(at: values) : result.end(before: values)
        }
        if let limit = query.limit {
            result = result.limit(to: limit)
        }
        return result
    }

    /// Traduit une erreur du SDK en erreur du module.
    ///
    /// Le message d'un index manquant contient l'URL de création : elle est extraite ici
    /// plutôt que laissée à chaque appelant.
    static func translate(_ error: any Error, path: String?) -> FirestoreError {
        let nsError = error as NSError
        let reason = nsError.localizedDescription

        guard let code = FirestoreErrorCode.Code(rawValue: nsError.code) else {
            return .unknown(path: path, code: nsError.code, reason: reason)
        }

        return switch code {
        case .permissionDenied: .permissionDenied(path: path ?? "", reason: reason)
        case .notFound: .notFound(path: path ?? "")
        case .alreadyExists: .alreadyExists(path: path ?? "")
        case .unavailable: .unavailable(reason: reason)
        case .unauthenticated: .unauthenticated(reason: reason)
        case .deadlineExceeded: .deadlineExceeded(path: path ?? "")
        case .failedPrecondition: .failedPrecondition(reason: reason, indexURL: indexURL(in: reason))
        case .resourceExhausted: .resourceExhausted(reason: reason)
        case .aborted: .aborted(reason: reason)
        case .invalidArgument: .invalidArgument(path: path ?? "", reason: reason)
        case .cancelled: .cancelled
        default: .unknown(path: path, code: nsError.code, reason: reason)
        }
    }

    private static func indexURL(in message: String) -> URL? {
        guard let range = message.range(of: #"https://console\.firebase\.google\.com/\S+"#, options: .regularExpression) else {
            return nil
        }
        return URL(string: String(message[range]))
    }
}

/// La transaction adossée au SDK.
///
/// `Transaction` n'est pas `Sendable` — le SDK compile en mode Swift 5 — mais cette
/// instance ne vit que le temps du corps synchrone que Firestore exécute, et n'en sort
/// jamais. L'annotation constate cette portée, elle ne promet rien d'autre.
private final class LiveTransaction: TransactionContext, @unchecked Sendable {

    private let transaction: Transaction
    private let database: Firestore

    init(transaction: Transaction, database: Firestore) {
        self.transaction = transaction
        self.database = database
    }

    func document<Value: FirestoreValue>(
        at path: DocumentPath<Value>
    ) throws(FirestoreError) -> Value? {
        let snapshot: DocumentSnapshot
        do {
            snapshot = try transaction.getDocument(database.document(path.path))
        } catch {
            throw LiveFirestore.translate(error, path: path.path)
        }

        guard snapshot.exists else { return nil }
        do {
            return try snapshot.data(as: Value.self)
        } catch {
            throw .decodingFailed(path: path.path, type: "\(Value.self)", reason: "\(error)")
        }
    }

    func set<Value: FirestoreValue>(_ value: Value, at path: DocumentPath<Value>, merge: Bool) {
        guard let fields = try? LiveFirestore.encode(value, at: path.path) else { return }
        transaction.setData(fields, forDocument: database.document(path.path), merge: merge)
    }

    func update<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        at path: DocumentPath<Value>
    ) {
        transaction.updateData(
            LiveFirestore.firestoreFields(fields),
            forDocument: database.document(path.path)
        )
    }

    func delete<Value: FirestoreValue>(at path: DocumentPath<Value>) {
        transaction.deleteDocument(database.document(path.path))
    }
}

private extension FirestoreMetadata {
    /// Traduit les métadonnées du SDK.
    ///
    /// Les deux drapeaux de Firestore sont exactement ceux dont une app a besoin pour
    /// dire la vérité : d'où vient la donnée, et si ce qu'on voit est déjà confirmé.
    init(_ metadata: SnapshotMetadata) {
        self.init(
            isFromCache: metadata.isFromCache,
            hasPendingWrites: metadata.hasPendingWrites
        )
    }
}

private extension ReadSource {
    var firestoreSource: FirestoreSource {
        switch self {
        case .default: .default
        case .server: .server
        case .cache: .cache
        }
    }
}
#endif
