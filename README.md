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

### Collections

Une clé désigne une valeur ; une collection en désigne un nombre quelconque, adressées par
identifiant. C'est ce qu'il faut pour garder localement ce qu'une API a rendu.

```swift
extension PersistenceCollection where Value == Profile {
    static let profiles = PersistenceCollection("profiles")
}

try await store.save(profile, id: profile.id, in: .profiles)
let un    = try await store.load(id: "u1", from: .profiles)
let tous  = try await store.loadAll(from: .profiles)
let actifs = try await store.filter(.profiles) { $0.visits > 10 }
let ids   = try await store.ids(in: .profiles)        // sans charger les valeurs
try await store.removeAll(from: .profiles)
```

Une collection `profiles` et une clé `profiles` ne se croisent jamais. `loadAll` **jette**
dès qu'une entrée est illisible : après un changement de modèle, on veut le savoir et
vider, pas récupérer un sous-ensemble amputé en silence.

### Fraîcheur

Toute valeur est horodatée à l'écriture. De quoi décider entre le cache local et un appel
réseau, sans tenir un registre à côté :

```swift
if let entry = try await store.stored(.catalog),
   !entry.isStale(after: .seconds(3600)) {
    return entry.value
}
return try await network.send(FetchCatalog())
```

```swift
// ou, plus court
if try await store.needsRefresh(.catalog, after: .seconds(3600)) { … }
```

`stored(_:)` distingue aussi « jamais écrit » de « écrit une valeur égale au défaut », ce
que `load(_:)` ne peut pas faire.

### Supports disponibles

| Support | Pour quoi |
|---|---|
| `.userDefaults` | Petites valeurs de préférence. Le défaut. |
| `.userDefaultsSuite(named:)` | App group partagé, ou isolation d'un test. |
| `.jsonFile(named:)` | Un document JSON unique. Réécrit en entier à chaque écriture : parfait pour des réglages, inadapté à une grosse collection. |
| `.jsonDirectory(named:)` | Un fichier JSON **par clé**. Le support des collections volumineuses. |
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

## SUNetworking

Appeler une API HTTP, sans que l'app connaisse `URLSession`.

### Déclarer ses services et ses endpoints

**Le module n'en déclare aucun** — comme pour les clés de `SUPersistence`, ils appartiennent
à l'app.

```swift
import SUNetworking

extension APIService {
    static let account: APIService = "account"
}

extension APIEnvironment {
    static let production = APIEnvironment([
        .account: URL(string: "https://api.lensy.app/v1")!
    ])
}

struct FetchProfile: Endpoint {
    typealias Response = Profile

    let userID: String
    var service: APIService { .account }
    var path: String { "/users/\(userID)" }
    var authentication: AuthRequirement { .required }
}
```

Tout a un défaut sauf le service, le chemin et le type de réponse : un `GET` public tient
en trois lignes, et le décodage JSON est fourni dès que `Response` est `Decodable`.

### Monter le store

```swift
@main
struct LensyApp: App {
    private let network = NetworkStore(
        environment: .production,
        middlewares: [
            DefaultHeadersMiddleware(["Accept": "application/json"]),
            TokenMiddleware(provider: FirebaseTokenProvider()),
            RetryMiddleware(),
        ]
    )

    var body: some Scene {
        WindowGroup { RootView() }
            .environment(network)
    }
}
```

`NetworkStore` n'a **pas** de `shared` : il lui faut les URL de base de vos services, que
seule l'app connaît. Un singleton sans environnement ne pourrait que planter ou mentir.

### Appeler

```swift
struct ProfileView: View {
    @Environment(NetworkStore.self) private var network
    @State private var profile: Profile?

    var body: some View {
        content
            .overlay { if network.isLoading { ProgressView() } }
            .task { profile = try? await network.send(FetchProfile(userID: "42")) }
    }
}
```

`isLoading` et `lastError` sont observés : de quoi piloter un indicateur global et une
bannière d'erreur sans les câbler à la main.

### Middlewares

| Middleware | Rôle |
|---|---|
| `DefaultHeadersMiddleware` | En-têtes communs. Un en-tête posé par l'endpoint n'est jamais écrasé. |
| `TokenMiddleware` | Joint un jeton, et rejoue **une** fois sur 401 avec un jeton rafraîchi. |
| `RetryMiddleware` | Rejoue les pannes transitoires : backoff exponentiel avec jitter, `Retry-After` respecté, verbes non idempotents épargnés. |
| `LoggingMiddleware` | Raconte chaque requête au `NetworkLogger` de l'app. |

L'ordre compte : le premier est le plus extérieur. `RetryMiddleware` se place **après**
`TokenMiddleware`, pour que chaque tentative reparte avec un jeton valide.

### Cloud Functions appelables

Le format `onCall` emballe la requête dans `{"data": …}` et rend `{"result": …}`.
`SUNetworking` connaît l'enveloppe.

Un type par fonction, quand elle a une identité :

```swift
struct SendFeedback: CallableEndpoint {
    typealias Response = Confirmation
    let payload: Feedback
    var functionName: String { "sendFeedback" }
}

let confirmation = try await network.send(SendFeedback(payload: feedback))
```

Ou la forme courte, réglable au point d'appel :

```swift
let confirmation: Confirmation = try await network.send(
    Callable("sendFeedback", payload: feedback)
)

// une fonction sans argument
let stats: Stats = try await network.send(Callable("dailyStats"))

// et tout est réglable, un paramètre à la fois
let confirmation: Confirmation = try await network.send(
    Callable(
        "sendFeedback",
        payload: feedback,
        headers: ["X-Debug": "1"],
        authentication: .optional,
        policy: RequestPolicy(timeout: .seconds(5), retry: .none)
    )
)
```

Les défauts — `POST`, authentification obligatoire, chemin égal au nom de la fonction,
service `.cloudFunctions` — tiennent tant qu'on ne les touche pas. Surcharger l'un n'en
fait perdre aucun autre.

`.cloudFunctions` n'est **qu'un nom** : l'URL reste dans votre `APIEnvironment`.

### Firebase sans le SDK Firebase

`TokenMiddleware` ne connaît pas Firebase. Il demande un jeton à un `TokenProvider`, que
l'app implémente :

```swift
struct FirebaseTokenProvider: TokenProvider {
    func token(forceRefresh: Bool) async throws -> String? {
        try await Auth.auth().currentUser?.getIDToken(forcingRefresh: forceRefresh)
    }
}
```

Le même middleware sert pour App Check, sur un autre en-tête et sans schéma :

```swift
TokenMiddleware(provider: AppCheckProvider(), header: "X-Firebase-AppCheck", scheme: nil)
```

Aucune dépendance n'entre dans le package, et toute la chaîne d'authentification se teste
avec un fournisseur de trois lignes.

### Tester

`MockTransport` ne touche jamais au réseau, et enregistre ce qu'on lui demande — de quoi
affirmer *comment* la requête a été formée, pas seulement ce qu'elle a rendu.

```swift
let transport = MockTransport([.status(200, json: #"{"name":"Florent"}"#)])
let store = NetworkStore(environment: .production, transport: transport)

let profile = try await store.send(FetchProfile(userID: "42"))

#expect(profile.name == "Florent")
#expect(await transport.lastRequest?.headers["Authorization"] != nil)
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
