import Foundation

/// « Est-ce la première fois ? »
///
/// Le besoin revient dans presque toutes les apps : ne montrer un onboarding qu'une fois,
/// n'expliquer une permission qu'au premier refus, ne signaler une nouveauté qu'au premier
/// lancement après une mise à jour. C'est un booléen persisté, mais avec assez de pièges —
/// défaut trompeur, double affichage sur appels concurrents — pour mériter son vocabulaire.
extension PersistenceStore {

    /// Dit si `key` a déjà été vue, en interrogeant le support.
    ///
    /// C'est la réponse à utiliser pour décider d'un premier affichage : elle est exacte
    /// même si rien n'a encore été chargé. Elle met le cache à jour au passage.
    ///
    /// ```swift
    /// .task {
    ///     if try await store.hasBeenSeen(.onboarding) == false {
    ///         showOnboarding = true
    ///     }
    /// }
    /// ```
    public func hasBeenSeen(_ key: SeenKey) async throws(PersistenceError) -> Bool {
        try await load(key.persistenceKey)
    }

    /// Ce que le cache sait de `key`, sans toucher au support. Synchrone et observée, donc
    /// appelable dans un `body`.
    ///
    /// > Important : rend `false` tant que la clé n'a pas été chargée — et `false` veut
    /// > dire « jamais vue ». N'en faites pas la condition d'un premier affichage sans
    /// > avoir appelé ``hasBeenSeen(_:)`` avant, sinon un utilisateur de longue date
    /// > reverra son onboarding.
    public func hasBeenSeenCached(_ key: SeenKey) -> Bool {
        value(for: key.persistenceKey)
    }

    /// Écrit l'état « vu » de `key`.
    ///
    /// Passer `false` remet la marque à zéro — pratique pour un bouton « revoir
    /// l'introduction », ou un menu de debug.
    public func setHasBeenSeen(_ seen: Bool, for key: SeenKey) async throws(PersistenceError) {
        try await save(seen, for: key.persistenceKey)
    }

    /// Marque `key` comme vue, et dit si c'était la première fois.
    ///
    /// C'est la forme à préférer quand la lecture sert uniquement à décider d'un affichage :
    /// elle évite le `hasBeenSeen` suivi d'un `setHasBeenSeen` où un appel concurrent
    /// pourrait se glisser.
    ///
    /// ```swift
    /// .task {
    ///     showOnboarding = try await store.markAsSeen(.onboarding)
    /// }
    /// ```
    ///
    /// - Returns: `true` si `key` n'avait jamais été vue, `false` sinon.
    ///
    /// Deux appels concurrents sur la même clé ne rendent `true` qu'une seule fois : le
    /// second voit qu'un marquage est en cours et se retire. La garantie vaut au sein d'un
    /// processus — deux cibles distinctes partageant une suite peuvent encore s'ignorer.
    @discardableResult
    public func markAsSeen(_ key: SeenKey) async throws(PersistenceError) -> Bool {
        let persistenceKey = key.persistenceKey

        // Lecture et insertion sans point de suspension entre les deux : sur le main actor,
        // un second appel ne peut pas s'intercaler ici.
        guard seenMarkingInFlight.insert(persistenceKey.name).inserted else { return false }
        defer { seenMarkingInFlight.remove(persistenceKey.name) }

        guard try await load(persistenceKey) == false else { return false }
        try await save(true, for: persistenceKey)
        return true
    }
}
