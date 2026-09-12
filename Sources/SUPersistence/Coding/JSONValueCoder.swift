import Foundation

/// Le codeur JSON, format par défaut du module.
///
/// Les dates sont en ISO 8601 et les clés triées : deux valeurs identiques produisent
/// toujours les mêmes octets, ce qui rend les fichiers comparables et les tests stables.
public struct JSONValueCoder: ValueCoder {

    public init() {}

    public func encode<Value: Encodable>(_ value: Value) throws(CodingFailure) -> Data {
        do {
            return try makeEncoder().encode(value)
        } catch {
            throw .encoding(type: "\(Value.self)", reason: error.localizedDescription)
        }
    }

    public func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws(CodingFailure) -> Value {
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw .decoding(type: "\(Value.self)", reason: error.localizedDescription)
        }
    }

    // `JSONEncoder` et `JSONDecoder` sont des classes mutables et non `Sendable` : les
    // garder en propriété rendrait ce type non `Sendable` à son tour. On en fabrique un
    // par appel — le coût est négligeable devant l'accès disque qui suit.
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
