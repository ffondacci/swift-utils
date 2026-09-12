import Foundation

/// Une valeur comparable dans une requête.
///
/// Le type est fermé et `Sendable` : un `Any` traverserait les frontières d'isolation sans
/// que le compilateur puisse rien en dire.
public enum QueryValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case date(Date)
    case array([QueryValue])
    case null
}

extension QueryValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension QueryValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension QueryValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension QueryValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension QueryValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension QueryValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: QueryValue...) { self = .array(elements) }
}

/// La comparaison d'un filtre.
public enum QueryComparison: String, Sendable, Hashable, CaseIterable {
    case isEqualTo
    case isNotEqualTo
    case isLessThan
    case isLessThanOrEqualTo
    case isGreaterThan
    case isGreaterThanOrEqualTo
    case arrayContains
    case arrayContainsAny
    case isIn
    case isNotIn
}

/// Ce qui restreint et ordonne une lecture de collection.
///
/// Se construit par chaînage, et chaque étape rend une nouvelle valeur — une requête est
/// une description, pas un objet qu'on mute :
///
/// ```swift
/// try await store.documents(in: .profiles) {
///     $0.where("visits", .isGreaterThan, 10)
///       .order(by: "name")
///       .limit(to: 20)
/// }
/// ```
/// > Le nom évite `FirestoreQuery`, déjà pris par un property wrapper du SDK Firebase.
/// > Une app qui importe les deux modules aurait eu une ambiguïté à chaque usage.
public struct DocumentQuery: Sendable, Equatable {

    public struct Filter: Sendable, Equatable {
        public let field: String
        public let comparison: QueryComparison
        public let value: QueryValue
    }

    public struct Ordering: Sendable, Equatable {
        public let field: String
        public let descending: Bool
    }

    /// Une borne de pagination.
    ///
    /// Les valeurs correspondent, **dans l'ordre**, aux champs de ``orderings``. Une
    /// requête triée sur deux champs prend donc deux valeurs.
    public struct Cursor: Sendable, Equatable {
        public enum Bound: Sendable, Equatable {
            /// Inclut le point de départ.
            case startAt
            /// L'exclut — la forme à utiliser pour paginer.
            case startAfter
            /// Inclut le point d'arrivée.
            case endAt
            /// L'exclut.
            case endBefore
        }

        public let bound: Bound
        public let values: [QueryValue]
    }

    public private(set) var filters: [Filter] = []
    public private(set) var orderings: [Ordering] = []
    public private(set) var limit: Int?
    public private(set) var start: Cursor?
    public private(set) var end: Cursor?

    public init() {}

    /// Ne garder que les documents dont `field` satisfait la comparaison.
    public func `where`(
        _ field: String,
        _ comparison: QueryComparison,
        _ value: QueryValue
    ) -> DocumentQuery {
        var copy = self
        copy.filters.append(Filter(field: field, comparison: comparison, value: value))
        return copy
    }

    /// Trier par `field`.
    ///
    /// > Firestore exige un index composite dès qu'on combine un filtre d'inégalité et un
    /// > tri sur un autre champ. L'erreur ``FirestoreError/failedPrecondition(reason:indexURL:)``
    /// > porte alors l'URL de création.
    public func order(by field: String, descending: Bool = false) -> DocumentQuery {
        var copy = self
        copy.orderings.append(Ordering(field: field, descending: descending))
        return copy
    }

    /// Limiter le nombre de documents rendus.
    public func limit(to count: Int) -> DocumentQuery {
        var copy = self
        copy.limit = count
        return copy
    }

    // MARK: - Pagination

    /// Reprendre **après** ces valeurs. C'est la forme de la pagination.
    ///
    /// Le motif : trier, limiter, puis relancer en partant après la dernière valeur lue.
    ///
    /// ```swift
    /// var cursor: QueryValue?
    /// repeat {
    ///     let page = try await store.documents(in: .profiles) {
    ///         var query = $0.order(by: "name").limit(to: 50)
    ///         if let cursor { query = query.start(after: [cursor]) }
    ///         return query
    ///     }
    ///     cursor = page.last.map { .string($0.value.name) }
    /// } while !page.isEmpty
    /// ```
    ///
    /// > Un curseur n'a de sens qu'avec un ``order(by:descending:)`` : c'est le tri qui
    /// > définit ce que « après » veut dire.
    public func start(after values: [QueryValue]) -> DocumentQuery {
        var copy = self
        copy.start = Cursor(bound: .startAfter, values: values)
        return copy
    }

    /// Reprendre **à partir de** ces valeurs, celles-ci incluses.
    public func start(at values: [QueryValue]) -> DocumentQuery {
        var copy = self
        copy.start = Cursor(bound: .startAt, values: values)
        return copy
    }

    /// S'arrêter **à** ces valeurs, celles-ci incluses.
    public func end(at values: [QueryValue]) -> DocumentQuery {
        var copy = self
        copy.end = Cursor(bound: .endAt, values: values)
        return copy
    }

    /// S'arrêter **avant** ces valeurs.
    public func end(before values: [QueryValue]) -> DocumentQuery {
        var copy = self
        copy.end = Cursor(bound: .endBefore, values: values)
        return copy
    }

    /// Vrai si la requête ne restreint rien — toute la collection.
    public var isUnrestricted: Bool {
        filters.isEmpty && orderings.isEmpty && limit == nil && start == nil && end == nil
    }
}
