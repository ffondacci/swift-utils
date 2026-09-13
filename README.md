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

Une fonction qui ne rend rien répond `{"result": null}`. `NoResult` absorbe le cas :

```swift
let _: NoResult = try await network.send(Callable("markAsRead", payload: id))
```

Et une `HttpsError` remonte **typée**, pas en JSON à parser :

```swift
catch NetworkError.serviceFailed(_, let code, let message) {
    // code == "PERMISSION_DENIED", message == "pas le droit"
}
```

C'est le point d'accroche `Endpoint.mapError(_:statusCode:)`, disponible pour n'importe
quelle API qui décrit ses échecs. Son défaut rend `nil`, et le client produit alors son
erreur générique — un corps d'une forme inattendue n'est jamais réinterprété de force.

> Ces formats ne sont pas devinés : ils sont vérifiés contre un émulateur Firebase réel.
> Voir `Tests/Fixtures/emulator/`.

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

## SUFirestore

Lire, écrire et interroger Firestore, sans que l'app connaisse le SDK.

> **Le SDK Firebase est derrière un trait.** Sans lui, `firebase-ios-sdk` n'est ni
> téléchargé ni compilé — 0 octet pour une app qui ne fait que de la persistance. Avec, ce
> sont 144 Mo et 14 paquets, assumés.
>
> Dans Xcode, cocher le trait **Firebase** au moment d'ajouter le paquet. En ligne de
> commande : `swift build --traits Firebase`.

### Déclarer ses chemins

```swift
import SUFirestore

extension CollectionPath where Value == Profile {
    static let profiles = CollectionPath("profiles")
}
```

### Monter le store

```swift
import FirebaseCore
import SUFirestoreLive

init() {
    AppCheck.setAppCheckProviderFactory(MyFactory())   // AVANT
    FirebaseApp.configure()                             // puis
    firestore = FirestoreStore(
        client: RetryingFirestore(
            wrapping: LiveFirestore(configuration: FirestoreConfiguration(
                offlinePersistence: false      // le cache disque, désactivé par défaut
            )),
            policy: .default
        )
    )
}
```

`SUFirestore` ne configure **jamais** Firebase : `FirebaseApp.configure()` doit être appelé
exactement une fois, et seule l'app peut le garantir. App Check s'installe avant.

### CRUD

```swift
let profile = try await store.document("u1", in: .profiles)          // nil si absent
try await store.setDocument(profile, id: "u1", in: .profiles)        // remplace
try await store.setDocument(patch, id: "u1", in: .profiles, merge: true)   // fusionne
try await store.updateDocument(["visits": 5], id: "u1", in: .profiles)     // doit exister
try await store.deleteDocument(id: "u1", in: .profiles)
```

### Requêtes

```swift
let actifs = try await store.documents(in: .profiles) {
    $0.where("visits", .isGreaterThan, 10)
      .where("premium", .isEqualTo, true)
      .order(by: "name")
      .limit(to: 20)
}
```

### Lots atomiques

```swift
try await store.batch { batch in
    batch.set(profile, id: "u1", in: .profiles, merge: true)
    batch.update(["count": 3], id: "global", in: .stats)
    batch.delete(id: draftID, in: .drafts)
}
```

Ou tout passe, ou rien. Au-delà de 500 écritures, le lot est refusé **avant** d'atteindre
le réseau.

### Reprise sur contention

Deux appareils qui écrivent le même document au même instant : Firestore en abandonne un
avec `aborted`. `RetryingFirestore` rejoue, et la seconde tentative trouve la voie libre.

| Rejoué | Jamais rejoué |
|---|---|
| `aborted` (contention) | `permissionDenied` |
| `unavailable` (réseau) | `notFound`, `alreadyExists` |
| `resourceExhausted` (quota) | `decodingFailed` |
| `deadlineExceeded` | `failedPrecondition` |

Backoff exponentiel avec jitter — sans l'aléa, les deux écritures qui se sont percutées
reviendraient exactement ensemble.

> Les écritures Firestore sont **absolues** (`set`, `update`, `delete` décrivent un état
> final), donc les rejouer aboutit au même document. C'est ce qui autorise la reprise sur
> les écritures ici, là où `SUNetworking` épargne les `POST`.

### Opérations serveur, pagination, provenance

```swift
try await store.updateDocument(["visits": .increment(1)], id: "u1", in: .profiles)
try await store.updateDocument(["tags": .arrayUnion(["beta"])], id: "u1", in: .profiles)

let page = try await store.documents(in: .profiles) {
    $0.order(by: "name").start(after: [cursor]).limit(to: 50)
}

if let snapshot = try await store.snapshot("u1", in: .profiles),
   snapshot.metadata.isFromCache {
    banner = "Hors ligne"
}
```

`increment` est la **seule** opération relative du module, et une écriture qui en contient
une n'est jamais rejouée — la rejouer après un timeout douteux compterait deux fois.

### Transactions

Un lot écrit sans lire. Une transaction **lit d'abord et décide ensuite** — ce qu'il faut
dès que la nouvelle valeur dépend de l'ancienne autrement que par un incrément.

```swift
try await store.transaction { transaction in
    guard let compte = try transaction.document("c1", in: .comptes),
          compte.solde >= montant
    else {
        throw InsufficientFunds()          // n'importe quelle erreur abandonne
    }
    transaction.set(compte.débité(de: montant), id: "c1", in: .comptes)
}
```

Deux règles que le double en mémoire **vérifie**, pour qu'on les découvre en test et non en
production :

- **Toutes les lectures avant toutes les écritures.** Firestore l'impose ; lire après avoir
  écrit jette une `invalidArgument`.
- **Le corps peut être rejoué** en cas de conflit — n'y mettez aucun effet de bord.

### Erreurs

`FirestoreError` nomme les codes plutôt que de les compter : `permissionDenied`,
`notFound`, `unavailable`, `unauthenticated`, `aborted`, `failedPrecondition`… Et
`failedPrecondition` **extrait l'URL de création de l'index** que Firestore glisse dans
son message.

```swift
catch let error where error.requiresReauthentication { showLogin() }
catch let error where error.isRetryable { showOfflineBanner() }
```

### Tester

`InMemoryFirestore` honore le même contrat — écritures, requêtes, lots, atomicité — sans
projet Firebase, sans réseau, et **sans le SDK dans le graphe de dépendances** :

```swift
let store = FirestoreStore.inMemory()
try await store.setDocument(profile, id: "u1", in: .profiles)
```

Il ne rejoue ni les règles de sécurité, ni les index composites : il teste **votre** code,
pas Firestore.

Et pour vérifier que le double dit bien la vérité, `Tests/Fixtures/emulator/` fait tourner
les mêmes scénarios contre un **vrai Firestore** local :

```bash
cd Tests/Fixtures/emulator
firebase emulators:start --only functions,firestore --project demo-swift-utils
SU_EMULATOR=1 swift test --traits Firebase
```

Aucun projet Firebase n'existe derrière — `demo-` est reconnu comme factice.

---

## SUAuth

Connexion, état de session, jetons, gestion de compte. L'adaptateur `FirebaseAuth` vit dans
`SUAuthLive`, derrière le trait **Firebase**.

### Trois états, pas deux

```swift
switch auth.state {
case .unknown:         ProgressView()      // la session se restaure
case .signedOut:       SignInScreen()
case .signedIn(let u): HomeScreen(user: u)
}
```

**C'est le piège numéro un.** Confondre `unknown` avec `signedOut` fait clignoter un écran
de connexion devant quelqu'un qui était déjà connecté. Le store s'abonne tout seul au flux
d'état à sa construction.

### Se connecter

```swift
try await auth.signUp(email: email, password: password)
try await auth.signIn(email: email, password: password)
try await auth.signInAnonymously()
try await auth.signOut()

// Fournisseurs tiers : aucun SDK de connexion dans le module
try await auth.signIn(with: ProviderCredential(provider: .apple, idToken: token, rawNonce: nonce))
```

### Savoir où on en est

```swift
if auth.isAnonymous       { CreateAccountBanner() }
if auth.hasPermanentAccount { ProfileScreen() }
```

Les deux ne sont pas l'inverse l'un de l'autre : déconnecté, les deux valent `false`.

### Lier un compte anonyme sans perdre ses données

```swift
let anonyme = try await auth.signInAnonymously()
let lié = try await auth.link(ProviderCredential(provider: .apple, idToken: token))
lié.id == anonyme.id        // vrai — tout ce qui est rattaché à cet id survit
```

### Les opérations sensibles

```swift
do {
    try await auth.updatePassword(nouveau)
} catch let error where error.requiresReauthentication {
    try await auth.reauthenticate(password: ancien)
    try await auth.updatePassword(nouveau)
}
```

### Le pont vers SUNetworking

```swift
struct FirebaseTokens: TokenProvider {
    let auth: AuthStore
    func token(forceRefresh: Bool) async throws -> String? {
        try await auth.idToken(forceRefresh: forceRefresh)
    }
}
```

### Trois propriétés d'erreur, trois réactions

| | Ce que l'app fait |
|---|---|
| `isUserCorrectable` | afficher le message **sous le champ** concerné |
| `requiresReauthentication` | demander le mot de passe, puis rejouer |
| `isRetryable` | proposer de réessayer |

---

## SUStorage

Téléverser, télécharger et lister des fichiers. L'adaptateur Firebase Storage vit dans
`SUStorageLive`, derrière le trait **Firebase** ; le reste n'a aucune dépendance.

```swift
extension StorageFolder {
    static let images: StorageFolder = "images"
}

// Téléverser depuis un fichier — une 4K ne passe pas par la mémoire
try await storage.upload(
    fileAt: localURL,
    to: .images.object("u1/photo.jpg"),
    metadata: UploadMetadata(contentType: "image/jpeg", custom: ["width": "3840"])
) { progress in
    self.fraction = progress.fraction        // nil si le total est inconnu
}

// Télécharger vers un fichier
try await storage.download(.images.object("u1/photo.jpg"), to: destination)

// En mémoire, sous garde de 10 Mo par défaut
let thumbnail = try await storage.data(.images.object("u1/thumb.jpg"))

let info = try await storage.metadata(of: .images.object("u1/photo.jpg"))
let page = try await storage.list(in: .images, limit: 100)
try await storage.delete(.images.object("u1/photo.jpg"))
```

### La progression est observée

```swift
@Environment(StorageStore.self) private var storage

if let fraction = storage.overallProgress { ProgressView(value: fraction) }
```

Un transfert terminé disparaît de `transfers`, réussi ou non — la liste décrit ce qui se
passe, pas un historique.

### Trois gardes qui évitent des bugs silencieux

- **Les chemins sont normalisés** : `/images//u1/photo.jpg/` et `images/u1/photo.jpg` sont
  le même objet. Sans ça, une barre de trop crée un fichier que l'app ne retrouve jamais.
- **`data(_:)` plafonne à 10 Mo** et jette au-delà, plutôt que de charger une 4K en RAM.
- **`fraction` vaut `nil`** quand le serveur n'annonce pas de total — une barre déterminée
  serait un mensonge.

---

## SULogger

Tracer ce que l'app fait, sans dépendance par défaut.

```swift
import SULogger

Log.configure(.default)                       // OSLog, tout niveau

Log.info("session démarrée")
Log.error("échec : \(error)", category: .network)
Log.debug("cache relu", category: .persistence)
```

Trois catégories — `app`, `network`, `persistence` — qui deviennent la `category` d'OSLog :
c'est elle qui permet de filtrer dans Console.app ou `log stream` sans tout noyer.

### Le message n'est construit que s'il sert

```swift
Log.debug("\(gros.description)")      // en production, jamais évalué
```

C'est un `@autoclosure` : filtré par le niveau ou la catégorie, la chaîne n'est **jamais**
construite. Un test le vérifie en comptant les constructions.

### Régler

```swift
Log.configure(LogConfiguration(
    minimumLevel: .warning,               // en dessous, rien
    categories: [.network],               // isoler un domaine
    destinations: [OSLogDestination()]
))
```

`.silent` coupe tout — pratique en test.

### Écrire dans un fichier

Disponible par défaut, sans dépendance.

```swift
let file = try FileDestination()                        // Library/Logs/app.log
Log.configure(LogConfiguration(destinations: [OSLogDestination(), file]))

// pour un rapport de support
let urls = file.allFileURLs
let poids = file.totalSize
try file.reset()
```

Rotation par taille (5 Mo) et nombre d'archives (3) par défaut. La rotation a lieu **avant**
l'écriture : la ligne la plus récente est toujours dans le fichier courant, et aucun fichier
ne dépasse la taille annoncée.

> Le handle reste ouvert et la taille est suivie en mémoire. Rouvrir et re-`stat` le
> fichier à chaque ligne a un coût mesuré dans `UniLogger`, qui l'a corrigé de la même
> façon.

### Les autres modules tracent déjà

`SUPersistence`, `SUNetworking` et `SUFirestore` dépendent de `SULogger` et écrivent
d'eux-mêmes — rien à câbler.

| Catégorie | Qui écrit |
|---|---|
| `persistence` | clés lues et écrites, absences, **échecs de décodage** |
| `network` | départ et arrivée de chaque requête, 4xx/5xx en avertissement |
| `firestore` | chemins, merges, lots, transactions, **reprises sur contention** |

`SULogger` est **la seule** exception à la règle « les modules sont indépendants » : c'est
une brique transverse, et elle n'a aucune dépendance externe.

Pour router ailleurs — Crashlytics, Sentry — il reste les points d'extension :

```swift
LoggingMiddleware(logger: MonLoggerÀMoi())          // côté réseau
Log.add(CrashlyticsDestination())                    // pour tout le reste
```

### Détailler un chemin sans inonder le reste

```swift
try await Log.withConfiguration(LogConfiguration(minimumLevel: .debug)) {
    try await leCheminQuOnDébogue()
}
```

La configuration est **task-local** : elle vaut pour cet arbre de tâches et lui seul. Les
autres gardent la configuration globale — ce qui rend aussi les tests parallèles sûrs.

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
