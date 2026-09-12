# swift-utils

Boîte à outils Swift. Chaque utilitaire est un module et un produit SPM indépendants, à
consommer à la carte.

- **Plateformes** : iOS 18+, macOS 15+, watchOS 11+, tvOS 18+, visionOS 2+
- **Swift** : 6 (concurrence stricte)
- **Dépendances** : aucune, hors SDK Apple

```swift
.package(url: "https://github.com/ffondacci/swift-utils.git", from: "1.0.0")
```

---

## SUPersistence

Sauvegarder et relire des valeurs, sans que l'app sache où elles sont rangées.

### Déclarer ses clés

Une clé lie un nom de stockage, un type, et la valeur rendue quand rien n'a été écrit.

```swift
import SUPersistence

extension PersistenceKey where Value == Bool {
    static let onboardingDone = PersistenceKey("onboardingDone", default: false)
}

extension PersistenceKey where Value == Profile? {
    static let currentProfile = PersistenceKey("currentProfile", default: nil)
}
```

### Injecter le store

```swift
@main
struct LensyApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .environment(PersistenceStore.shared)
    }
}
```

`PersistenceStore.shared` s'adosse à `UserDefaults.standard`. Pour un autre support :

```swift
let store = try PersistenceStore(.jsonFile(named: "settings"))
let preview = PersistenceStore.inMemory()
```

### Lire et écrire

```swift
struct RootView: View {
    @Environment(PersistenceStore.self) private var store

    var body: some View {
        Toggle("Onboarding vu", isOn: .constant(store[.onboardingDone]))
            .task { try? await store.load(.onboardingDone) }
    }
}
```

La lecture par `store[.key]` est **synchrone et observée** : elle rend ce qui est en
cache, et la vue se redessine quand le cache change. `load(_:)` va chercher la valeur sur
le support, `save(_:for:)` l'y écrit — les deux sont `async throws`.

```swift
try await store.save(true, for: .onboardingDone)
try await store.remove(.onboardingDone)
try await store.removeAll()
```

### « Est-ce la première fois ? »

Le besoin revient dans presque toutes les apps : ne montrer un onboarding qu'une fois,
n'expliquer une permission qu'au premier refus, ne signaler une nouveauté qu'une fois par
mise à jour. Le store a un vocabulaire dédié pour ça.

```swift
extension SeenKey {
    static let onboarding: SeenKey = "onboarding"
    static let cameraExplainer: SeenKey = "cameraExplainer"
}
```

```swift
// Marque la chose comme vue, et dit si c'était la première fois.
.task {
    showOnboarding = try await store.markAsSeen(.onboarding)
}

// Ou séparément
let seen = try await store.hasBeenSeen(.onboarding)
try await store.setHasBeenSeen(false, for: .onboarding)   // « revoir l'introduction »
```

`markAsSeen(_:)` est la forme à préférer quand la lecture ne sert qu'à décider d'un
affichage : deux appels concurrents sur la même clé ne rendent `true` qu'une seule fois,
là où un `hasBeenSeen` suivi d'un `setHasBeenSeen` laisserait passer un double affichage.

`hasBeenSeenCached(_:)` existe aussi, synchrone et observée pour les `body`. Attention à
son défaut : elle rend `false` tant que la clé n'a pas été chargée, et `false` veut dire
« jamais vue ». Ne l'utilisez pas seule pour décider d'un premier affichage.

Les marques vivent dans leur propre espace de noms : une marque `onboarding` n'écrase
jamais une préférence `onboarding`.

### Supports disponibles

| Support | Pour quoi |
|---|---|
| `.userDefaults` | Petites valeurs de préférence. Le défaut. |
| `.userDefaultsSuite(named:)` | App group partagé, ou isolation d'un test. |
| `.jsonFile(named:)` | Valeurs structurées, dans un document JSON d'Application Support. |
| `.inMemory` | Previews SwiftUI et tests. Rien n'atteint le disque. |

SwiftData et SQLite viendront s'ajouter comme backends supplémentaires, sans changement
d'API.

### Architecture

```
Store ────────── surface publique, @MainActor @Observable, cache observé
Repository ───── typage, clés, valeurs par défaut
Coder ────────── Value <-> Data
Backend ──────── Data <-> support physique
```

Chaque couche ne connaît que le **protocole** de celle du dessous. Un backend maison se
branche sans toucher au reste :

```swift
struct KeychainBackend: PersistenceBackend { /* … */ }

let store = PersistenceStore(
    repository: CodableRepository(backend: KeychainBackend())
)
```

### Erreurs

Tout ce qui peut échouer est `async throws(PersistenceError)`. Le type d'erreur est dans
la signature, et chaque cas porte de quoi diagnostiquer — clé, type, raison :

```swift
do {
    try await store.load(.currentProfile)
} catch {
    print(error)  // Décodage de Profile impossible pour la clé « currentProfile » : …
}
```

---

## Développement

Ouvrir le package seul, pour le travailler et lancer ses tests :

```bash
open Package.swift
swift test
```

Pour l'éditer **en direct** depuis une app consommatrice, voir la section
« Intégration dans une app » de `CLAUDE.md` : la dépendance reste déclarée par URL remote,
et un workspace de développement l'override en local.
