import Foundation
import Testing
@testable import SUFirestore

struct Account: Codable, Sendable, Equatable {
    var owner: String
    var balance: Int
}

/// Hors du `@MainActor` du suite : le corps d'une transaction est `@Sendable`, il ne peut
/// pas atteindre une propriété isolée sur le main actor.
let accounts = CollectionPath<Account>("accounts")

/// Lire, décider, écrire. Ce qu'un lot ne sait pas faire — il écrit sans jamais lire.
@MainActor
@Suite("Transactions")
struct TransactionTests {

    @Test("une transaction lit puis écrit en fonction de ce qu'elle a lu")
    func readThenWrite() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(Account(owner: "Florent", balance: 100), id: "a", in: accounts)

        try await store.transaction { transaction in
            guard let account = try transaction.document("a", in: accounts) else { return }
            transaction.set(
                Account(owner: account.owner, balance: account.balance - 30),
                id: "a", in: accounts
            )
        }

        let loaded = try await store.document("a", in: accounts)
        #expect(loaded?.balance == 70)
    }

    @Test("une transaction touche plusieurs documents d'un seul coup")
    func multiDocumentTransfer() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(Account(owner: "A", balance: 100), id: "a", in: accounts)
        try await store.setDocument(Account(owner: "B", balance: 0), id: "b", in: accounts)

        try await store.transaction { transaction in
            guard let source = try transaction.document("a", in: accounts),
                  let target = try transaction.document("b", in: accounts)
            else { return }
            transaction.set(Account(owner: source.owner, balance: source.balance - 40), id: "a", in: accounts)
            transaction.set(Account(owner: target.owner, balance: target.balance + 40), id: "b", in: accounts)
        }

        let a = try await store.document("a", in: accounts)
        let b = try await store.document("b", in: accounts)
        #expect(a?.balance == 60)
        #expect(b?.balance == 40)
    }

    @Test("un abandon volontaire n'écrit rien")
    func voluntaryCancellationWritesNothing() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(Account(owner: "Florent", balance: 10), id: "a", in: accounts)

        let error = await #expect(throws: FirestoreError.self) {
            try await store.transaction { transaction in
                guard let account = try transaction.document("a", in: accounts),
                      account.balance >= 50
                else {
                    throw FirestoreError.transactionCancelled(reason: "solde insuffisant")
                }
                transaction.set(Account(owner: account.owner, balance: 0), id: "a", in: accounts)
            }
        }

        #expect(error == .transactionCancelled(reason: "solde insuffisant"))

        let loaded = try await store.document("a", in: accounts)
        #expect(loaded?.balance == 10, "le compte n'a pas bougé")
    }

    @Test("un abandon volontaire n'est jamais rejoué")
    func cancellationIsNotRetryable() {
        let cancelled = FirestoreError.transactionCancelled(reason: "règle métier")
        let contention = FirestoreError.aborted(reason: "contention")

        // La distinction compte : une règle métier qui refuse ne changera pas d'avis en
        // réessayant, une contention si.
        #expect(cancelled.isRetryable == false)
        #expect(contention.isRetryable == true)
    }

    @Test("une transaction qui échoue en cours n'applique aucune de ses écritures")
    func partialFailureWritesNothing() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(Account(owner: "A", balance: 100), id: "a", in: accounts)

        _ = await #expect(throws: FirestoreError.self) {
            try await store.transaction { transaction in
                transaction.set(Account(owner: "A", balance: 0), id: "a", in: accounts)
                transaction.update(["balance": 1], id: "inexistant", in: accounts)  // échoue
            }
        }

        let loaded = try await store.document("a", in: accounts)
        #expect(loaded?.balance == 100, "la première écriture n'a pas été publiée non plus")
    }

    @Test("lire après avoir écrit est refusé, comme chez Firestore")
    func readAfterWriteIsRejected() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(Account(owner: "A", balance: 100), id: "a", in: accounts)

        let error = await #expect(throws: FirestoreError.self) {
            try await store.transaction { transaction in
                transaction.set(Account(owner: "A", balance: 50), id: "a", in: accounts)
                _ = try transaction.document("a", in: accounts)   // trop tard
            }
        }

        guard case let .invalidArgument(_, reason) = error else {
            Issue.record("attendu .invalidArgument, reçu \(String(describing: error))")
            return
        }
        #expect(reason.contains("avant"))
    }

    @Test("les lectures voient un état figé, pas les écritures en cours")
    func readsSeeAFrozenSnapshot() async throws {
        let (store, _) = makeStore()
        try await store.setDocument(Account(owner: "A", balance: 100), id: "a", in: accounts)
        try await store.setDocument(Account(owner: "B", balance: 200), id: "b", in: accounts)

        try await store.transaction { transaction in
            let a = try transaction.document("a", in: accounts)
            let b = try transaction.document("b", in: accounts)
            // Les deux lectures voient bien l'état d'avant la transaction.
            transaction.set(Account(owner: "A", balance: (a?.balance ?? 0) + (b?.balance ?? 0)), id: "a", in: accounts)
        }

        let loaded = try await store.document("a", in: accounts)
        #expect(loaded?.balance == 300)
    }

    @Test("un document absent se lit en nil dans une transaction")
    func missingDocumentReadsAsNil() async throws {
        let (store, _) = makeStore()

        try await store.transaction { transaction in
            let account = try transaction.document("jamais", in: accounts)
            #expect(account == nil)
        }
    }
}
