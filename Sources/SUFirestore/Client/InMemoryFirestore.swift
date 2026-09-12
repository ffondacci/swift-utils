import Foundation

/// Un Firestore qui ne quitte jamais le processus.
///
/// Il honore le même contrat que le vrai, ce qui permet de tester une app entière — ses
/// écritures, ses requêtes, ses lots — sans projet Firebase, sans réseau, et sans le SDK
/// dans le graphe de dépendances.
///
/// Ses limites sont assumées : il ne rejoue ni les règles de sécurité, ni les index
/// composites, ni la cohérence éventuelle. Il teste **votre** code, pas Firestore.
public actor InMemoryFirestore: FirestoreClient {

    /// Les documents, par chemin, en JSON.
    private var documents: [String: Data] = [:]

    /// Les erreurs à lever aux prochains appels, pour tester les chemins d'échec.
    private var scheduledErrors: [FirestoreError] = []

    /// Le nombre d'appels reçus — la mesure d'un test de reprise.
    public private(set) var callCount = 0

    /// La provenance que le double annonce. Par défaut « synchronisé » : il n'a pas de
    /// cache. La changer permet de tester ce qu'une app affiche hors ligne.
    public var metadata: FirestoreMetadata = .synchronized

    /// Fait annoncer au double que ses lectures viennent du cache.
    public func simulate(_ metadata: FirestoreMetadata) {
        self.metadata = metadata
    }

    public init() {}

    /// Sème un contenu initial.
    public func seed<Value: FirestoreValue>(_ value: Value, at path: String) throws(FirestoreError) {
        documents[path] = try encode(value, at: path)
    }

    /// Fait échouer le prochain appel, quel qu'il soit.
    public func failNextCall(with error: FirestoreError) {
        scheduledErrors = [error]
    }

    /// Fait échouer les `count` prochains appels, puis laisse passer.
    ///
    /// C'est ce qui rend un test de reprise lisible : on programme les échecs, et on
    /// vérifie que le succès finit par arriver.
    public func failNextCalls(_ count: Int, with error: FirestoreError) {
        scheduledErrors = Array(repeating: error, count: count)
    }

    /// Les chemins actuellement stockés — pour affirmer dans un test.
    public var storedPaths: [String] { documents.keys.sorted() }

    // MARK: - Lecture

    public func document<Value: FirestoreValue>(
        _ type: Value.Type,
        at path: String,
        source: ReadSource
    ) throws(FirestoreError) -> FirestoreDocument<Value>? {
        try consumeScheduledError()
        guard let data = documents[path] else { return nil }
        return FirestoreDocument(
            id: path.split(separator: "/").last.map(String.init) ?? path,
            value: try decode(type, from: data, at: path),
            metadata: metadata
        )
    }

    // Pas de `@concurrent` ici : les méthodes d'un acteur tournent déjà sur son propre
    // executor, jamais sur le main actor. L'annotation ne s'applique qu'aux
    // implémentations nonisolated.
    public func documents<Value: FirestoreValue>(
        _ type: Value.Type,
        in path: String,
        query: DocumentQuery,
        source: ReadSource
    ) throws(FirestoreError) -> FirestoreQueryResult<Value> {
        try consumeScheduledError()

        let prefix = "\(path)/"
        var matches: [(id: String, fields: [String: Any], data: Data)] = []

        for (documentPath, data) in documents {
            guard documentPath.hasPrefix(prefix) else { continue }
            let identifier = String(documentPath.dropFirst(prefix.count))
            // Un identifiant qui contient encore un `/` appartient à une sous-collection.
            guard !identifier.contains("/") else { continue }
            guard let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            guard query.filters.allSatisfy({ Self.matches(fields[$0.field], $0) }) else { continue }
            matches.append((identifier, fields, data))
        }

        for ordering in query.orderings.reversed() {
            matches.sort { left, right in
                let comparison = Self.compare(left.fields[ordering.field], right.fields[ordering.field])
                return ordering.descending ? comparison > 0 : comparison < 0
            }
        }
        if query.orderings.isEmpty {
            matches.sort { $0.id < $1.id }
        }
        if let cursor = query.start {
            matches = Self.apply(cursor, to: matches, orderings: query.orderings)
        }
        if let cursor = query.end {
            matches = Self.apply(cursor, to: matches, orderings: query.orderings)
        }
        if let limit = query.limit {
            matches = Array(matches.prefix(limit))
        }

        var results: [FirestoreDocument<Value>] = []
        results.reserveCapacity(matches.count)
        for match in matches {
            let value = try decode(Value.self, from: match.data, at: "\(path)/\(match.id)")
            results.append(FirestoreDocument(id: match.id, value: value, metadata: metadata))
        }
        return FirestoreQueryResult(documents: results, metadata: metadata)
    }

    // MARK: - Écriture

    public func setDocument<Value: FirestoreValue>(
        _ value: Value,
        at path: String,
        merge: Bool
    ) throws(FirestoreError) {
        try consumeScheduledError()
        try write(try encode(value, at: path), at: path, merge: merge)
    }

    public func updateDocument(
        _ fields: [String: DocumentField],
        at path: String
    ) throws(FirestoreError) {
        try consumeScheduledError()
        guard let existing = documents[path] else { throw .notFound(path: path) }

        guard var object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
            throw .decodingFailed(path: path, type: "document", reason: "contenu illisible")
        }
        Self.apply(fields, to: &object)
        guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
            throw .encodingFailed(path: path, type: "document", reason: "champs non sérialisables")
        }
        documents[path] = encoded
    }

    public func deleteDocument(at path: String) throws(FirestoreError) {
        try consumeScheduledError()
        documents.removeValue(forKey: path)
    }

    public func commit(_ operations: [DocumentWrite]) throws(FirestoreError) {
        try consumeScheduledError()

        // Atomique comme le vrai : on prépare tout, et on ne publie qu'ensuite. Une
        // opération qui échoue laisse le magasin exactement dans son état d'avant.
        var staged = documents
        for operation in operations {
            switch operation {
            case let .set(path, value, merge):
                let data = try encode(value, at: path)
                staged[path] = merge ? try merged(data, into: staged[path], at: path) : data

            case let .update(path, fields):
                guard let existing = staged[path] else { throw .notFound(path: path) }
                guard var object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                    throw .decodingFailed(path: path, type: "document", reason: "contenu illisible")
                }
                Self.apply(fields, to: &object)
                guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
                    throw .encodingFailed(path: path, type: "document", reason: "champs non sérialisables")
                }
                staged[path] = encoded

            case let .delete(path):
                staged.removeValue(forKey: path)
            }
        }
        documents = staged
    }

    // MARK: - Transactions

    public func runTransaction(
        _ body: @Sendable @escaping (any TransactionContext) throws -> Void
    ) throws(FirestoreError) {
        try consumeScheduledError()

        let transaction = InMemoryTransaction(snapshot: documents)
        do {
            try body(transaction)
        } catch let error as FirestoreError {
            throw error
        } catch {
            throw FirestoreError.transactionCancelled(reason: "\(error)")
        }

        // Atomique comme le reste : on prépare, on publie ensuite.
        var staged = documents
        for operation in transaction.collectedWrites {
            switch operation {
            case let .set(path, value, merge):
                let data = try encode(value, at: path)
                staged[path] = merge ? try merged(data, into: staged[path], at: path) : data
            case let .update(path, fields):
                guard let existing = staged[path] else { throw .notFound(path: path) }
                guard var object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
                    throw .decodingFailed(path: path, type: "document", reason: "contenu illisible")
                }
                Self.apply(fields, to: &object)
                guard let encoded = try? JSONSerialization.data(withJSONObject: object) else {
                    throw .encodingFailed(path: path, type: "document", reason: "champs non sérialisables")
                }
                staged[path] = encoded
            case let .delete(path):
                staged.removeValue(forKey: path)
            }
        }
        documents = staged
    }

    // MARK: - Octets

    private func write(_ data: Data, at path: String, merge: Bool) throws(FirestoreError) {
        documents[path] = merge ? try merged(data, into: documents[path], at: path) : data
    }

    private func merged(
        _ incoming: Data,
        into existing: Data?,
        at path: String
    ) throws(FirestoreError) -> Data {
        guard let existing,
              var base = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any],
              let new = (try? JSONSerialization.jsonObject(with: incoming)) as? [String: Any]
        else {
            return incoming
        }
        for (key, value) in new { base[key] = value }
        guard let encoded = try? JSONSerialization.data(withJSONObject: base) else {
            throw .encodingFailed(path: path, type: "document", reason: "fusion non sérialisable")
        }
        return encoded
    }

    private func encode<Value: FirestoreValue>(
        _ value: Value,
        at path: String
    ) throws(FirestoreError) -> Data {
        let encoder = JSONEncoder()
        // Secondes depuis 1970, pas ISO 8601 : l'ISO perd les fractions de seconde et se
        // compare comme du texte, alors que Firestore garde les nanosecondes et trie
        // numériquement. Un test vert ici doit rester vert en production.
        encoder.dateEncodingStrategy = .secondsSince1970
        do {
            return try encoder.encode(value)
        } catch {
            throw .encodingFailed(path: path, type: "\(Value.self)", reason: error.localizedDescription)
        }
    }

    private func decode<Value: FirestoreValue>(
        _ type: Value.Type,
        from data: Data,
        at path: String
    ) throws(FirestoreError) -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw .decodingFailed(path: path, type: "\(Value.self)", reason: "\(error)")
        }
    }

    private func consumeScheduledError() throws(FirestoreError) {
        callCount += 1
        guard !scheduledErrors.isEmpty else { return }
        throw scheduledErrors.removeFirst()
    }

    /// Coupe la liste triée selon la borne.
    ///
    /// La comparaison est lexicographique sur les champs de tri, exactement comme
    /// Firestore la fait : c'est le tri qui définit ce que « après » veut dire.
    private static func apply(
        _ cursor: DocumentQuery.Cursor,
        to matches: [(id: String, fields: [String: Any], data: Data)],
        orderings: [DocumentQuery.Ordering]
    ) -> [(id: String, fields: [String: Any], data: Data)] {
        guard !orderings.isEmpty else { return matches }
        let bounds = cursor.values.map(jsonValue(of:))

        func position(of match: (id: String, fields: [String: Any], data: Data)) -> Int {
            for (index, ordering) in orderings.enumerated() where index < bounds.count {
                let result = compare(match.fields[ordering.field], bounds[index])
                let adjusted = ordering.descending ? -result : result
                if adjusted != 0 { return adjusted }
            }
            return 0
        }

        return matches.filter { match in
            switch cursor.bound {
            case .startAt: position(of: match) >= 0
            case .startAfter: position(of: match) > 0
            case .endAt: position(of: match) <= 0
            case .endBefore: position(of: match) < 0
            }
        }
    }

    // MARK: - Évaluation des filtres

    /// Applique des champs à un document, en traitant les cas qui ne sont pas des valeurs.
    private static func apply(_ fields: [String: DocumentField], to object: inout [String: Any]) {
        for (key, field) in fields {
            switch field {
            case .deleteField:
                object.removeValue(forKey: key)
            case .serverTimestamp:
                // Le double n'a pas de serveur : il pose l'heure locale, ce qui suffit à
                // vérifier qu'un horodatage arrive bien. La justesse de l'heure, elle, ne
                // se teste que contre un vrai Firestore.
                object[key] = Date.now.timeIntervalSince1970
            case let .string(text): object[key] = text
            case let .int(number): object[key] = number
            case let .double(number): object[key] = number
            case let .bool(flag): object[key] = flag
            case let .date(date): object[key] = date.timeIntervalSince1970
            case let .array(values): object[key] = values.map(jsonValue(of:))
            case .null: object[key] = NSNull()

            case let .increment(amount):
                let current = (object[key] as? NSNumber)?.doubleValue ?? 0
                object[key] = current + amount

            case let .arrayUnion(elements):
                var array = object[key] as? [Any] ?? []
                for element in elements.map(jsonValue(of:))
                where !array.contains(where: { equal($0, element) }) {
                    array.append(element)
                }
                object[key] = array

            case let .arrayRemove(elements):
                let removed = elements.map(jsonValue(of:))
                let array = object[key] as? [Any] ?? []
                object[key] = array.filter { candidate in
                    !removed.contains { equal(candidate, $0) }
                }
            }
        }
    }

    private static func jsonValue(of value: DocumentField) -> Any {
        switch value {
        case let .string(text): text
        case let .int(number): number
        case let .double(number): number
        case let .bool(flag): flag
        case let .date(date): date.timeIntervalSince1970
        case let .array(values): values.map(jsonValue(of:))
        case .serverTimestamp: Date.now.timeIntervalSince1970
        case .deleteField: NSNull()
        case let .increment(amount): amount
        case let .arrayUnion(values): values.map(jsonValue(of:))
        case let .arrayRemove(values): values.map(jsonValue(of:))
        case .null: NSNull()
        }
    }

    private static func jsonValue(of value: QueryValue) -> Any {
        switch value {
        case let .string(text): text
        case let .int(number): number
        case let .double(number): number
        case let .bool(flag): flag
        case let .date(date): date.timeIntervalSince1970
        case let .array(values): values.map(jsonValue(of:))
        case .null: NSNull()
        }
    }

    private static func matches(_ field: Any?, _ filter: DocumentQuery.Filter) -> Bool {
        let expected = jsonValue(of: filter.value)

        switch filter.comparison {
        case .isEqualTo: return equal(field, expected)
        case .isNotEqualTo: return !equal(field, expected)
        case .isLessThan: return compare(field, expected) < 0
        case .isLessThanOrEqualTo: return compare(field, expected) <= 0
        case .isGreaterThan: return compare(field, expected) > 0
        case .isGreaterThanOrEqualTo: return compare(field, expected) >= 0
        case .arrayContains:
            guard let array = field as? [Any] else { return false }
            return array.contains { equal($0, expected) }
        case .arrayContainsAny:
            guard let array = field as? [Any], let candidates = expected as? [Any] else { return false }
            return array.contains { element in candidates.contains { equal(element, $0) } }
        case .isIn:
            guard let candidates = expected as? [Any] else { return false }
            return candidates.contains { equal(field, $0) }
        case .isNotIn:
            guard let candidates = expected as? [Any] else { return false }
            return !candidates.contains { equal(field, $0) }
        }
    }

    private static func equal(_ left: Any?, _ right: Any?) -> Bool {
        switch (left, right) {
        case (nil, nil), (is NSNull, is NSNull): true
        case let (left as String, right as String): left == right
        case let (left as Bool, right as Bool): left == right
        case let (left as NSNumber, right as NSNumber): left == right
        default: false
        }
    }

    /// -1, 0 ou 1. Deux valeurs incomparables rendent 0 — l'ordre reste stable.
    private static func compare(_ left: Any?, _ right: Any?) -> Int {
        switch (left, right) {
        case let (left as String, right as String):
            return left == right ? 0 : (left < right ? -1 : 1)
        case let (left as NSNumber, right as NSNumber):
            return left == right ? 0 : (left.doubleValue < right.doubleValue ? -1 : 1)
        default:
            return 0
        }
    }
}
