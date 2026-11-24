# swift-utils

A Swift toolbox. Every utility is an independent module and SPM product, to pick à la
carte.

- **Platforms**: iOS 18+, macOS 15+, watchOS 11+, tvOS 18+, visionOS 2+
- **Swift**: 6 (strict concurrency)
- **Dependencies**: none beyond the Apple SDKs

```swift
.package(url: "https://github.com/ffondacci/swift-utils.git", from: "1.0.0")
```

---

## SUPersistence

Save and read back values, without the app knowing where they are stored.

### Declare your keys

A key binds a storage name, a type, and the value returned when nothing has been written.

```swift
import SUPersistence

extension PersistenceKey where Value == Bool {
    static let onboardingDone = PersistenceKey("onboardingDone", default: false)
}

extension PersistenceKey where Value == Profile? {
    static let currentProfile = PersistenceKey("currentProfile", default: nil)
}
```

### Inject the store

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
            .environment(PersistenceStore.shared)
    }
}
```

`PersistenceStore.shared` is backed by `UserDefaults.standard`. For another medium:

```swift
let store = try PersistenceStore(.jsonFile(named: "settings"))
let preview = PersistenceStore.inMemory()
```

### Read and write

```swift
struct RootView: View {
    @Environment(PersistenceStore.self) private var store

    var body: some View {
        Toggle("Onboarding seen", isOn: .constant(store[.onboardingDone]))
            .task { try? await store.load(.onboardingDone) }
    }
}
```

Reading through `store[.key]` is **synchronous and observed**: it returns what is cached,
and the view redraws when the cache changes. `load(_:)` fetches the value from the medium,
`save(_:for:)` writes it there; both are `async throws`.

```swift
try await store.save(true, for: .onboardingDone)
try await store.remove(.onboardingDone)
try await store.removeAll()
```

### "Is this the first time?"

Almost every app needs it: show an onboarding only once, explain a permission only after
the first refusal, announce a new feature once per update. The store has a dedicated
vocabulary for it.

```swift
extension SeenKey {
    static let onboarding: SeenKey = "onboarding"
    static let cameraExplainer: SeenKey = "cameraExplainer"
}
```

```swift
// Marks the thing as seen, and tells whether it was the first time.
.task {
    showOnboarding = try await store.markAsSeen(.onboarding)
}

// Or separately
let seen = try await store.hasBeenSeen(.onboarding)
try await store.setHasBeenSeen(false, for: .onboarding)   // "show the intro again"
```

Prefer `markAsSeen(_:)` when the read only decides whether to show something: two
concurrent calls on the same key return `true` only once, where `hasBeenSeen` followed by
`setHasBeenSeen` would let a double display through.

`hasBeenSeenCached(_:)` also exists, synchronous and observed for `body`. Mind its default:
it returns `false` until the key has been loaded, and `false` means "never seen". Do not
use it alone to decide a first display.

Marks live in their own namespace: an `onboarding` mark never overwrites an `onboarding`
preference.

### Collections

A key names one value; a collection names any number of them, addressed by identifier.
That is what you need to keep locally what an API returned.

```swift
extension PersistenceCollection where Value == Profile {
    static let profiles = PersistenceCollection("profiles")
}

try await store.save(profile, id: profile.id, in: .profiles)
let one    = try await store.load(id: "u1", from: .profiles)
let all    = try await store.loadAll(from: .profiles)
let active = try await store.filter(.profiles) { $0.visits > 10 }
let ids    = try await store.ids(in: .profiles)        // without loading the values
try await store.removeAll(from: .profiles)
```

A `profiles` collection and a `profiles` key never collide. `loadAll` **throws** as soon as
one entry is unreadable: after a model change, you want to know and clear, not silently
get a truncated subset.

### Freshness

Every value is timestamped on write. Enough to choose between the local cache and a
network call, without keeping a separate registry:

```swift
if let entry = try await store.stored(.catalog),
   !entry.isStale(after: .seconds(3600)) {
    return entry.value
}
return try await network.send(FetchCatalog())
```

```swift
// or, shorter
if try await store.needsRefresh(.catalog, after: .seconds(3600)) { … }
```

`stored(_:)` also tells "never written" apart from "written a value equal to the default",
which `load(_:)` cannot do.

### Available media

| Medium | For what |
|---|---|
| `.userDefaults` | Small preference values. The default. |
| `.userDefaultsSuite(named:)` | Shared app group, or isolating a test. |
| `.jsonFile(named:)` | A single JSON document. Rewritten in full on every write: perfect for settings, wrong for a large collection. |
| `.jsonDirectory(named:)` | One JSON file **per key**. The medium for large collections. |
| `.inMemory` | SwiftUI previews and tests. Nothing reaches the disk. |

SwiftData and SQLite will come as additional backends, with no API change.

### Architecture

```
Store ────────── public surface, @MainActor @Observable, observed cache
Repository ───── typing, keys, default values
Coder ────────── Value <-> Data
Backend ──────── Data <-> physical medium
```

Each layer only knows the **protocol** of the one below. A custom backend plugs in
without touching the rest:

```swift
struct KeychainBackend: PersistenceBackend { /* … */ }

let store = PersistenceStore(
    repository: CodableRepository(backend: KeychainBackend())
)
```

### Errors

Everything that can fail is `async throws(PersistenceError)`. The error type is in the
signature, and every case carries what you need to diagnose it: key, type, reason.

```swift
do {
    try await store.load(.currentProfile)
} catch {
    print(error)  // Cannot decode Profile for key "currentProfile": …
}
```

---

## SUNetworking

Call an HTTP API, without the app knowing `URLSession`.

### Declare your services and endpoints

**The module declares none**: like the keys of `SUPersistence`, they belong to the app.

```swift
import SUNetworking

extension APIService {
    static let account: APIService = "account"
}

extension APIEnvironment {
    static let production = APIEnvironment([
        .account: URL(string: "https://api.example.com/v1")!
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

Everything has a default except the service, the path and the response type: a public
`GET` fits in three lines, and JSON decoding comes for free as soon as `Response` is
`Decodable`.

### Set up the store

```swift
@main
struct MyApp: App {
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

`NetworkStore` has **no** `shared`: it needs the base URLs of your services, which only the
app knows. A singleton without an environment could only crash or lie.

### Call

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

`isLoading` and `lastError` are observed: enough to drive a global spinner and an error
banner without wiring them by hand.

### Middlewares

| Middleware | Role |
|---|---|
| `DefaultHeadersMiddleware` | Common headers. A header set by the endpoint is never overwritten. |
| `TokenMiddleware` | Attaches a token, and replays **once** on 401 with a refreshed token. |
| `RetryMiddleware` | Replays transient failures: exponential backoff with jitter, `Retry-After` honored, non-idempotent verbs spared. |
| `LoggingMiddleware` | Reports every request to the app's `NetworkLogger`. |

Order matters: the first one is the outermost. Put `RetryMiddleware` **after**
`TokenMiddleware`, so every attempt starts again with a valid token.

### Callable Cloud Functions

The `onCall` format wraps the request in `{"data": …}` and returns `{"result": …}`.
`SUNetworking` knows the envelope.

One type per function, when it has an identity:

```swift
struct SendFeedback: CallableEndpoint {
    typealias Response = Confirmation
    let payload: Feedback
    var functionName: String { "sendFeedback" }
}

let confirmation = try await network.send(SendFeedback(payload: feedback))
```

Or the short form, tunable at the call site:

```swift
let confirmation: Confirmation = try await network.send(
    Callable("sendFeedback", payload: feedback)
)

// a function without arguments
let stats: Stats = try await network.send(Callable("dailyStats"))

// and everything is tunable, one parameter at a time
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

The defaults (`POST`, authentication required, path equal to the function name, service
`.cloudFunctions`) hold as long as you do not touch them. Overriding one loses none of the
others.

`.cloudFunctions` is **only a name**: the URL stays in your `APIEnvironment`.

A function that returns nothing answers `{"result": null}`. `NoResult` absorbs the case:

```swift
let _: NoResult = try await network.send(Callable("markAsRead", payload: id))
```

And an `HttpsError` comes back **typed**, not as JSON to parse:

```swift
catch NetworkError.serviceFailed(_, let code, let message) {
    // code == "PERMISSION_DENIED", message == "not allowed"
}
```

This is the `Endpoint.mapError(_:statusCode:)` hook, available to any API that describes
its failures. Its default returns `nil`, and the client then produces its generic error: a
body of an unexpected shape is never forcibly reinterpreted.

> These formats are not guessed: they are checked against a real Firebase emulator.
> See `Tests/Fixtures/emulator/`.

### Firebase without the Firebase SDK

`TokenMiddleware` does not know Firebase. It asks a `TokenProvider` for a token, which the
app implements:

```swift
struct FirebaseTokenProvider: TokenProvider {
    func token(forceRefresh: Bool) async throws -> String? {
        try await Auth.auth().currentUser?.getIDToken(forcingRefresh: forceRefresh)
    }
}
```

The same middleware serves App Check, on another header and without a scheme:

```swift
TokenMiddleware(provider: AppCheckProvider(), header: "X-Firebase-AppCheck", scheme: nil)
```

No dependency enters the package, and the whole authentication chain is testable with a
three-line provider.

### Testing

`MockTransport` never touches the network, and records what it is asked: enough to assert
*how* the request was built, not only what it returned.

```swift
let transport = MockTransport([.status(200, json: #"{"name":"Florent"}"#)])
let store = NetworkStore(environment: .production, transport: transport)

let profile = try await store.send(FetchProfile(userID: "42"))

#expect(profile.name == "Florent")
#expect(await transport.lastRequest?.headers["Authorization"] != nil)
```

---

## SUFirestore

Read, write and query Firestore, without the app knowing the SDK.

> **The Firebase SDK sits behind a trait.** Without it, `firebase-ios-sdk` is neither
> downloaded nor compiled: 0 bytes for an app that only does persistence. With it, 144 MB
> and 14 packages, knowingly.
>
> In Xcode, tick the **Firebase** trait when adding the package. From the command line:
> `swift build --traits Firebase`.

### Declare your paths

```swift
import SUFirestore

extension CollectionPath where Value == Profile {
    static let profiles = CollectionPath("profiles")
}
```

### Set up the store

```swift
import FirebaseCore
import SUFirestoreLive

init() {
    AppCheck.setAppCheckProviderFactory(MyFactory())   // FIRST
    FirebaseApp.configure()                             // then
    firestore = FirestoreStore(
        client: RetryingFirestore(
            wrapping: LiveFirestore(configuration: FirestoreConfiguration(
                offlinePersistence: false      // the disk cache, off by default
            )),
            policy: .default
        )
    )
}
```

`SUFirestore` **never** configures Firebase: `FirebaseApp.configure()` must be called
exactly once, and only the app can guarantee it. App Check goes in before.

### CRUD

```swift
let profile = try await store.document("u1", in: .profiles)          // nil if missing
try await store.setDocument(profile, id: "u1", in: .profiles)        // replaces
try await store.setDocument(patch, id: "u1", in: .profiles, merge: true)   // merges
try await store.updateDocument(["visits": 5], id: "u1", in: .profiles)     // must exist
try await store.deleteDocument(id: "u1", in: .profiles)
```

### Queries

```swift
let active = try await store.documents(in: .profiles) {
    $0.where("visits", .isGreaterThan, 10)
      .where("premium", .isEqualTo, true)
      .order(by: "name")
      .limit(to: 20)
}
```

### Atomic batches

```swift
try await store.batch { batch in
    batch.set(profile, id: "u1", in: .profiles, merge: true)
    batch.update(["count": 3], id: "global", in: .stats)
    batch.delete(id: draftID, in: .drafts)
}
```

All or nothing. Beyond 500 writes, the batch is refused **before** reaching the network.

### Retry on contention

Two devices writing the same document at the same moment: Firestore aborts one with
`aborted`. `RetryingFirestore` replays it, and the second attempt finds the way clear.

| Replayed | Never replayed |
|---|---|
| `aborted` (contention) | `permissionDenied` |
| `unavailable` (network) | `notFound`, `alreadyExists` |
| `resourceExhausted` (quota) | `decodingFailed` |
| `deadlineExceeded` | `failedPrecondition` |

Exponential backoff with jitter: without the randomness, the two writes that collided would
come back exactly together.

> Firestore writes are **absolute** (`set`, `update`, `delete` describe a final state), so
> replaying them ends in the same document. That is what allows retrying writes here, where
> `SUNetworking` spares `POST`.

### Server operations, pagination, provenance

```swift
try await store.updateDocument(["visits": .increment(1)], id: "u1", in: .profiles)
try await store.updateDocument(["tags": .arrayUnion(["beta"])], id: "u1", in: .profiles)

let page = try await store.documents(in: .profiles) {
    $0.order(by: "name").start(after: [cursor]).limit(to: 50)
}

if let snapshot = try await store.snapshot("u1", in: .profiles),
   snapshot.metadata.isFromCache {
    banner = "Offline"
}
```

`increment` is the **only** relative operation in the module, and a write that contains one
is never replayed: replaying it after an uncertain timeout would count twice.

### Transactions

A batch writes without reading. A transaction **reads first and decides next**: what you
need as soon as the new value depends on the old one other than through an increment.

```swift
try await store.transaction { transaction in
    guard let account = try transaction.document("a1", in: .accounts),
          account.balance >= amount
    else {
        throw InsufficientFunds()          // any error aborts
    }
    transaction.set(account.debited(by: amount), id: "a1", in: .accounts)
}
```

Two rules that the in-memory double **enforces**, so you find them in tests and not in
production:

- **All reads before all writes.** Firestore requires it; reading after writing throws
  `invalidArgument`.
- **The body may be replayed** on conflict: put no side effect in it.

### Errors

`FirestoreError` names the codes instead of numbering them: `permissionDenied`,
`notFound`, `unavailable`, `unauthenticated`, `aborted`, `failedPrecondition`… And
`failedPrecondition` **extracts the index-creation URL** that Firestore slips into its
message.

```swift
catch let error where error.requiresReauthentication { showLogin() }
catch let error where error.isRetryable { showOfflineBanner() }
```

### Testing

`InMemoryFirestore` honors the same contract (writes, queries, batches, atomicity) with no
Firebase project, no network, and **no SDK in the dependency graph**:

```swift
let store = FirestoreStore.inMemory()
try await store.setDocument(profile, id: "u1", in: .profiles)
```

It replays neither security rules nor composite indexes: it tests **your** code, not
Firestore.

And to check that the double tells the truth, `Tests/Fixtures/emulator/` runs the same
scenarios against a **real** local Firestore:

```bash
cd Tests/Fixtures/emulator
firebase emulators:start --only functions,firestore --project demo-swift-utils
SU_EMULATOR=1 swift test --traits Firebase
```

No Firebase project exists behind it: `demo-` is recognized as a placeholder.

---

## SUAuth

Sign-in, session state, tokens, account management. The `FirebaseAuth` adapter lives in
`SUAuthLive`, behind the **Firebase** trait.

### Three states, not two

```swift
switch auth.state {
case .unknown:         ProgressView()      // the session is being restored
case .signedOut:       SignInScreen()
case .signedIn(let u): HomeScreen(user: u)
}
```

**This is trap number one.** Mistaking `unknown` for `signedOut` flashes a sign-in screen
at someone who was already signed in. The store subscribes to the state stream on its own
when it is built.

### Signing in

```swift
try await auth.signUp(email: email, password: password)
try await auth.signIn(email: email, password: password)
try await auth.signInAnonymously()
try await auth.signOut()

// Third-party providers: no sign-in SDK in the module
try await auth.signIn(with: ProviderCredential(provider: .apple, idToken: token, rawNonce: nonce))
```

### Linking an anonymous account without losing its data

```swift
let anonymous = try await auth.signInAnonymously()
let linked = try await auth.link(ProviderCredential(provider: .apple, idToken: token))
linked.id == anonymous.id        // true: everything attached to this id survives
```

### Sensitive operations

```swift
do {
    try await auth.updatePassword(newPassword)
} catch let error where error.requiresReauthentication {
    try await auth.reauthenticate(password: oldPassword)
    try await auth.updatePassword(newPassword)
}
```

### The bridge to SUNetworking

```swift
struct FirebaseTokens: TokenProvider {
    let auth: AuthStore
    func token(forceRefresh: Bool) async throws -> String? {
        try await auth.idToken(forceRefresh: forceRefresh)
    }
}
```

### Three error properties, three reactions

| | What the app does |
|---|---|
| `isUserCorrectable` | show the message **under the field** concerned |
| `requiresReauthentication` | ask for the password, then replay |
| `isRetryable` | offer to try again |

---

## SUStorage

Upload, download and list files. The Firebase Storage adapter lives in `SUStorageLive`,
behind the **Firebase** trait; the rest has no dependency.

```swift
extension StorageFolder {
    static let images: StorageFolder = "images"
}

// Upload from a file: a 4K image never goes through memory
try await storage.upload(
    fileAt: localURL,
    to: .images.object("u1/photo.jpg"),
    metadata: UploadMetadata(contentType: "image/jpeg", custom: ["width": "3840"])
) { progress in
    self.fraction = progress.fraction        // nil if the total is unknown
}

// Download to a file
try await storage.download(.images.object("u1/photo.jpg"), to: destination)

// In memory, under a 10 MB guard by default
let thumbnail = try await storage.data(.images.object("u1/thumb.jpg"))

let info = try await storage.metadata(of: .images.object("u1/photo.jpg"))
let page = try await storage.list(in: .images, limit: 100)
try await storage.delete(.images.object("u1/photo.jpg"))
```

### Progress is observed

```swift
@Environment(StorageStore.self) private var storage

if let fraction = storage.overallProgress { ProgressView(value: fraction) }
```

A finished transfer leaves `transfers`, successful or not: the list describes what is
happening, not a history.

### Three guards against silent bugs

- **Paths are normalized**: `/images//u1/photo.jpg/` and `images/u1/photo.jpg` are the
  same object. Without that, one slash too many creates a file the app never finds again.
- **`data(_:)` caps at 10 MB** and throws beyond, rather than loading a 4K image in RAM.
- **`fraction` is `nil`** when the server announces no total: a determinate bar would be a
  lie.

---

## SULogger

Trace what the app does, with no dependency by default.

```swift
import SULogger

Log.configure(.default)                       // OSLog, every level

Log.info("session started")
Log.error("failed: \(error)", category: .network)
Log.debug("cache reloaded", category: .persistence)
```

Three categories (`app`, `network`, `persistence`) that become the OSLog `category`: it is
what lets you filter in Console.app or `log stream` without drowning in everything.

### The message is only built when it is used

```swift
Log.debug("\(huge.description)")      // never evaluated in production
```

It is an `@autoclosure`: filtered out by level or category, the string is **never** built.
A test checks it by counting the constructions.

### Tuning

```swift
Log.configure(LogConfiguration(
    minimumLevel: .warning,               // nothing below
    categories: [.network],               // isolate one domain
    destinations: [OSLogDestination()]
))
```

`.silent` turns everything off, handy in tests.

### Writing to a file

Available by default, with no dependency.

```swift
let file = try FileDestination()                        // Library/Logs/app.log
Log.configure(LogConfiguration(destinations: [OSLogDestination(), file]))

// for a support report
let urls = file.allFileURLs
let size = file.totalSize
try file.reset()
```

Rotation by size (5 MB) and archive count (3) by default. Rotation happens **before** the
write: the latest line is always in the current file, and no file exceeds the announced
size.

> The handle stays open and the size is tracked in memory. Reopening and re-`stat`ing the
> file on every line has a measurable cost.

### The other modules already log

`SUPersistence`, `SUNetworking` and `SUFirestore` depend on `SULogger` and write on their
own: nothing to wire.

| Category | Who writes |
|---|---|
| `persistence` | keys read and written, misses, **decoding failures** |
| `network` | start and end of every request, 4xx/5xx as warnings |
| `firestore` | paths, merges, batches, transactions, **contention retries** |

`SULogger` is **the only** exception to the "modules are independent" rule: it is a
cross-cutting brick, and it has no external dependency.

To route elsewhere (Crashlytics, Sentry), the extension points remain:

```swift
LoggingMiddleware(logger: MyLogger())                // network side
Log.add(CrashlyticsDestination())                    // for everything else
```

### Detailing one path without flooding the rest

```swift
try await Log.withConfiguration(LogConfiguration(minimumLevel: .debug)) {
    try await thePathBeingDebugged()
}
```

The configuration is **task-local**: it applies to this task tree and to it alone. The
others keep the global configuration, which also makes parallel tests safe.

---

## Development

Open the package on its own, to work on it and run its tests:

```bash
open Package.swift
swift test
```
