import Foundation

/// Ce qui peut rater pendant une conversion valeur ↔ octets.
///
/// Cette erreur ne connaît pas la clé concernée : un codeur ne voit qu'un type et des
/// octets. C'est le repository, une couche plus haut, qui la traduit en
/// `PersistenceError` en y ajoutant le contexte qui lui manque.
public enum CodingFailure: Error, Equatable, Sendable {
    case encoding(type: String, reason: String)
    case decoding(type: String, reason: String)

    var reason: String {
        switch self {
        case let .encoding(_, reason), let .decoding(_, reason): reason
        }
    }
}

/// La conversion entre une valeur et sa représentation stockée.
///
/// Isoler ça derrière un protocole permet de changer de format — JSON aujourd'hui, plist
/// ou binaire demain — sans toucher ni au stockage en dessous, ni au repository au-dessus.
public protocol ValueCoder: Sendable {
    func encode<Value: Encodable>(_ value: Value) throws(CodingFailure) -> Data
    func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws(CodingFailure) -> Value
}
