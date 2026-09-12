import Foundation

/// L'accès typé au stockage : des valeurs, des clés, des collections, des valeurs par
/// défaut, et la date de chaque écriture.
///
/// C'est ici que « il n'y a rien sous cette clé » devient « voici la valeur par défaut »,
/// et que les erreurs des couches basses reçoivent le contexte qui leur manquait.
///
/// Le store ne connaît que ce protocole. Il ignore donc s'il parle à `UserDefaults`, à un
/// fichier, ou à un double de test.
public protocol PersistenceRepository: Sendable {

    // MARK: - Valeurs

    /// La valeur rangée sous `key`, ou sa valeur par défaut si rien n'y a été écrit.
    func load<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> Value

    /// La valeur **et sa date d'écriture**, ou `nil` si rien n'a été écrit.
    ///
    /// À la différence de ``load(_:)``, elle distingue « jamais écrit » de « écrit une
    /// valeur égale au défaut ».
    func stored<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> StoredValue<Value>?

    /// Range `value` sous `key`, horodatée à maintenant.
    func save<Value: PersistentValue>(_ value: Value, for key: PersistenceKey<Value>) async throws(PersistenceError)

    /// Supprime `key`. Une relecture rendra ensuite sa valeur par défaut.
    func remove<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError)

    /// Indique si une valeur a été écrite sous `key`.
    func contains<Value: PersistentValue>(_ key: PersistenceKey<Value>) async throws(PersistenceError) -> Bool

    // MARK: - Collections

    /// Range `value` sous `id` dans `collection`.
    func save<Value: PersistentValue>(
        _ value: Value,
        id: String,
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError)

    /// L'entrée `id`, ou `nil` si elle n'existe pas.
    func load<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> Value?

    /// L'entrée `id` avec sa date d'écriture, ou `nil`.
    func stored<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> StoredValue<Value>?

    /// Toutes les entrées, par identifiant.
    ///
    /// - Throws: ``PersistenceError/decodingFailed(key:type:reason:)`` dès qu'**une** entrée
    ///   est illisible. C'est volontaire : après un changement de modèle, on veut le savoir
    ///   et vider la collection, pas récupérer un sous-ensemble silencieusement amputé.
    func loadAll<Value: PersistentValue>(
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> [String: Value]

    /// Les identifiants présents, sans charger les valeurs.
    func ids<Value: PersistentValue>(
        in collection: PersistenceCollection<Value>
    ) async throws(PersistenceError) -> [String]

    /// Supprime l'entrée `id`.
    func remove<Value: PersistentValue>(
        id: String,
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError)

    /// Vide la collection, sans toucher au reste.
    func removeAll<Value: PersistentValue>(
        from collection: PersistenceCollection<Value>
    ) async throws(PersistenceError)

    // MARK: - Tout

    /// Efface tout ce que ce repository a écrit.
    func removeAll() async throws(PersistenceError)
}

public extension PersistenceRepository {

    /// Les entrées qui satisfont `predicate`.
    ///
    /// Le filtrage a lieu **en mémoire**, après chargement : ce n'est pas une requête de
    /// base de données, et ça ne dispense pas de garder les collections d'une taille
    /// raisonnable. Le prédicat est `@Sendable`, ce que le compilateur vérifie — pas une
    /// promesse faite à la main.
    func filter<Value: PersistentValue>(
        _ collection: PersistenceCollection<Value>,
        where predicate: @Sendable (Value) -> Bool
    ) async throws(PersistenceError) -> [Value] {
        try await loadAll(from: collection).values.filter(predicate)
    }
}
