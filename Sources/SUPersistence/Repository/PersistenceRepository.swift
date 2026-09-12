import Foundation

/// L'accès typé au stockage : des valeurs, des clés, des valeurs par défaut.
///
/// C'est ici que « il n'y a rien sous cette clé » devient « voici la valeur par défaut »,
/// et que les erreurs des couches basses reçoivent le contexte qui leur manquait.
///
/// Le store ne connaît que ce protocole. Il ignore donc s'il parle à `UserDefaults`, à un
/// fichier, ou à un double de test.
public protocol PersistenceRepository: Sendable {

    /// La valeur rangée sous `key`, ou sa valeur par défaut si rien n'y a été écrit.
    func load<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> Value

    /// Range `value` sous `key`.
    func save<Value: PersistentValue>(_ value: Value, for key: PersistenceKey<Value>) async throws(PersistenceError)

    /// Supprime `key`. Une relecture rendra ensuite sa valeur par défaut.
    func remove<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError)

    /// Indique si une valeur a été écrite sous `key` — à distinguer de « la valeur vaut
    /// son défaut ».
    func contains<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> Bool

    /// Efface tout ce que ce repository a écrit.
    func removeAll() async throws(PersistenceError)
}
