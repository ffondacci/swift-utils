import Foundation
import Testing
@testable import SUFirestore

// MARK: - Valeurs

struct Profile: Codable, Sendable, Equatable {
    var name: String
    var visits: Int
    var premium: Bool = false
    var tags: [String] = []
}

struct Post: Codable, Sendable, Equatable {
    var title: String
}

// MARK: - Chemins

extension CollectionPath where Value == Profile {
    static let profiles = CollectionPath("profiles")
}

extension CollectionPath where Value == Post {
    static let posts = CollectionPath("posts")
}

// MARK: - Raccourcis

func profile(_ name: String, visits: Int = 0, premium: Bool = false, tags: [String] = []) -> Profile {
    Profile(name: name, visits: visits, premium: premium, tags: tags)
}

@MainActor
func makeStore() -> (store: FirestoreStore, client: InMemoryFirestore) {
    let client = InMemoryFirestore()
    return (FirestoreStore(client: client), client)
}
