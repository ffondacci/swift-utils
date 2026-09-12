import Foundation

/// Le corps d'une requête : des octets et leur type de contenu.
///
/// Le transport ne manipule que ça — il n'a pas à savoir ce que les octets représentent,
/// exactement comme un backend de `SUPersistence`.
public struct RequestBody: Sendable, Equatable {

    public let data: Data
    public let contentType: String

    public init(data: Data, contentType: String) {
        self.data = data
        self.contentType = contentType
    }

    /// Du JSON déjà sérialisé.
    public static func json(_ data: Data) -> RequestBody {
        RequestBody(data: data, contentType: "application/json")
    }

    /// Encode une valeur en JSON. Les dates partent en ISO 8601, les clés triées — deux
    /// valeurs identiques produisent les mêmes octets, ce qui rend les tests stables.
    public static func json(
        _ value: some Encodable
    ) throws(NetworkError) -> RequestBody {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return .json(try encoder.encode(value))
        } catch {
            throw .encodingFailed(reason: error.localizedDescription)
        }
    }

    /// Un formulaire `application/x-www-form-urlencoded`.
    public static func form(_ fields: [String: String]) -> RequestBody {
        var components = URLComponents()
        components.queryItems = fields
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = components.percentEncodedQuery ?? ""
        return RequestBody(
            data: Data(encoded.utf8),
            contentType: "application/x-www-form-urlencoded"
        )
    }

    /// Des octets bruts, type de contenu au choix.
    public static func raw(_ data: Data, contentType: String) -> RequestBody {
        RequestBody(data: data, contentType: contentType)
    }
}
