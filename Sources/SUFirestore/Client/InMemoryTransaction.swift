import Foundation
import Synchronization

/// La transaction du double en mémoire.
///
/// Elle lit dans un instantané figé au démarrage — comme le vrai Firestore, qui garantit
/// que les lectures d'une transaction voient un état cohérent — et accumule les écritures
/// jusqu'à la fin du corps.
///
/// Elle applique aussi la règle que Firestore impose : **toutes les lectures avant toutes
/// les écritures**. Mieux vaut la découvrir dans un test que dans les logs de production.
final class InMemoryTransaction: TransactionContext {

    private struct State {
        var snapshot: [String: Data]
        var writes: [DocumentWrite] = []
        var hasWritten = false
    }

    private let state: Mutex<State>

    init(snapshot: [String: Data]) {
        self.state = Mutex(State(snapshot: snapshot))
    }

    var collectedWrites: [DocumentWrite] {
        state.withLock(\.writes)
    }

    func document<Value: FirestoreValue>(
        at path: DocumentPath<Value>
    ) throws(FirestoreError) -> Value? {
        let data = try state.withLock { state throws(FirestoreError) -> Data? in
            guard !state.hasWritten else {
                throw FirestoreError.invalidArgument(
                    path: path.path,
                    reason: "une transaction lit tout avant d'écrire quoi que ce soit"
                )
            }
            return state.snapshot[path.path]
        }

        guard let data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return try decoder.decode(Value.self, from: data)
        } catch {
            throw .decodingFailed(path: path.path, type: "\(Value.self)", reason: "\(error)")
        }
    }

    func set<Value: FirestoreValue>(_ value: Value, at path: DocumentPath<Value>, merge: Bool) {
        record(.set(path: path.path, value: value, merge: merge))
    }

    func update<Value: FirestoreValue>(
        _ fields: [String: DocumentField],
        at path: DocumentPath<Value>
    ) {
        record(.update(path: path.path, fields: fields))
    }

    func delete<Value: FirestoreValue>(at path: DocumentPath<Value>) {
        record(.delete(path: path.path))
    }

    private func record(_ write: DocumentWrite) {
        state.withLock { state in
            state.writes.append(write)
            state.hasWritten = true
        }
    }
}
