# CLAUDE.md — swift-utils

## Le dépôt

`swift-utils` est un **package Swift multi-modules** : une boîte à outils dont chaque
utilitaire est un module et un produit SPM indépendants, que les apps consomment à la
carte. Rien n'est une app, rien n'a d'UI — ce sont des briques.

Premier consommateur : **Lensy** (`../lensy`, iOS 26.5). Le package vise plus bas que lui
volontairement — voir les décisions figées.

Modules existants :

- **`SUPersistence`** — sauvegarder et relire des valeurs et des collections, horodatées,
  via `UserDefaults` ou des fichiers `.json` aujourd'hui, via SwiftData / SQLite demain,
  **sans que l'app appelante change une ligne**.
- **`SUNetworking`** — appeler une API HTTP : endpoints typés, chaîne de middlewares
  (en-têtes, jeton, reprise, journal), transport remplaçable.
- **`SUFirestore`** — lire, écrire et interroger Firestore. L'adaptateur SDK vit dans
  `SUFirestoreLive`, derrière le trait `Firebase`.
- **`SULogger`** — tracer ce que l'app fait : `OSLog`, fichiers avec rotation, et une
  configuration surchargeable par arbre de tâches. Aucune dépendance.

Le journal est la seule surface qui **n'est pas** un store `@MainActor` : on trace depuis
n'importe où, et personne ne devrait écrire `await` pour laisser une trace.

C'est le test de l'architecture : si changer de backend ou de transport oblige à toucher
au code de l'app, l'architecture est ratée.

## Décisions figées

À ne pas re-débattre à chaque session. Les changer est une décision explicite de Florent.

| Sujet | Décision | Pourquoi |
|---|---|---|
| Plateformes | iOS 18 / macOS 15 / watchOS 11 / tvOS 18 / visionOS 2 | C'est le palier qui débloque `Mutex`, `@Observable` + `.environment()`, SwiftData et les typed throws, sans fermer la porte aux apps en production. |
| Toolchain | `// swift-tools-version: 6.2`, langage Swift 6 | Le mode langage 6 est le plus récent qui existe — il n'y a pas de mode 6.1 ou 6.2. C'est le **tools-version** qui donne accès aux évolutions récentes, et 6.2 débloque les traits SPM et la concurrence « approachable ». Le coût est d'exiger Xcode 26 chez le consommateur ; les seuls consommateurs sont les apps de Florent, qui y sont déjà. |
| Concurrence | `defaultIsolation(nil)`, `NonisolatedNonsendingByDefault`, `InferIsolatedConformances`, `ExistentialAny`, `strictMemorySafety` | Voir `commonSwiftSettings` dans `Package.swift` : chaque réglage change la sémantique, aucun n'est décoratif. `SUFirestoreLive` utilise `interopSwiftSettings`, identique mais sans `strictMemorySafety` : son métier est d'appeler un SDK Objective-C, que le réglage signalerait ligne par ligne sans rien apprendre. |
| Dépendances lourdes | Derrière un **trait SPM** | `firebase-ios-sdk` pèse 144 Mo et 14 paquets. Sans le trait `Firebase`, SwiftPM ne le télécharge même pas : une app qui ne veut que `SUPersistence` paie 0 octet. |
| Dépendances légères | **Pas de dépendance du tout** | Un trait ne se justifie que si la dépendance coûte cher. SwiftyBeaver (444 Ko) a été retiré : il ne portait plus qu'un pont dont aucune app ne se servait, et l'écrire nous-mêmes coûtait moins que le gérer. |
| Découpage | 1 utilitaire = 1 module = 1 produit `.library` | La frontière de module fait respecter la separation of concerns **par le compilateur**, pas par la discipline. |
| Nommage | Préfixe `SU` sur les **modules seulement** | Un nom de module est global chez le consommateur. Les types, eux, sont déjà namespacés par leur module : `import SUPersistence` puis `PersistenceStore`, pas `SUPersistenceStore`. |
| Point d'entrée | 1 store **par module** | Une app qui n'importe que `SUPersistence` ne traîne pas le reste. Pas de module chapeau qui dépendrait de tous les autres. |
| Singleton | Seulement quand un défaut a du sens | `PersistenceStore.shared` s'adosse à `UserDefaults.standard`, ce qui est un choix défendable sans rien savoir de l'app. `NetworkStore` n'a pas de `shared` : il lui faut les URL de base des services, que seule l'app connaît, et un singleton sans environnement ne pourrait que planter ou mentir. |
| Tests | Swift Testing | `async` natif, tests paramétrés, traits de parallélisme — aligné avec du code concurrency-first. |
| Dépendances | Aucune par défaut | Une brique qui traîne un arbre de dépendances n'est pas une brique. Ce qui en exige une vit derrière un trait, et ne coûte rien à qui ne l'active pas. |

## Le principe directeur : separation of concerns

C'est **la** règle du dépôt. Tout le reste en découle.

```
  ┌─ Store ────────── @MainActor @Observable, singleton. La seule surface que l'app touche.
  │                   Expose des fonctions métier, pas des primitives de stockage.
  ├─ Repository ───── Typage, clés, valeurs par défaut, migrations de schéma.
  ├─ Coder ────────── Value <-> Data (JSON, plist, …).
  └─ Backend ──────── Data <-> support physique (UserDefaults, fichier, SwiftData, SQLite…).
```

**Règle de dépendance** : une couche ne connaît que le **protocole** de la couche du
dessous, jamais son implémentation concrète, et ne connaît rien de la couche du dessus.
Le choix de l'implémentation se fait par injection, à la construction.

Trois conséquences qu'on vérifie à chaque revue :

- Ajouter un backend (SQLite, SwiftData…) ne doit toucher **aucun** fichier des couches
  supérieures. Si ça les touche, l'abstraction fuit.
- Aucun type de stockage ne remonte dans la signature du store. `PersistenceStore` ne
  mentionne ni `UserDefaults`, ni `URL`, ni `Data`, ni `ModelContext`.
- Chaque couche est testable seule, avec un double en mémoire de la couche du dessous.

## Personnalisation — tout a un défaut, tout est surchargeable

C'est la deuxième règle du dépôt, après la separation of concerns. Une API doit se
laisser utiliser en trois mots, **et** se laisser régler dans le détail sans qu'on ait à
renoncer aux autres défauts.

```swift
Callable("sendFeedback", payload: feedback)                    // le cas courant
Callable("sendFeedback", payload: feedback,                    // et tout le reste
         headers: ["X-Debug": "1"], authentication: .optional,
         policy: RequestPolicy(timeout: .seconds(5), retry: .none))
```

Concrètement :

- **Chaque paramètre a une valeur par défaut** dès qu'un choix raisonnable existe. Un
  appelant ne doit jamais fournir une valeur qu'il n'a pas d'avis dessus.
- **Surcharger un réglage n'en fait perdre aucun autre.** Pas de « mode avancé » qui
  oblige à tout redéclarer : ce sont des paramètres nommés indépendants, pas un objet de
  configuration à construire en entier.
- **Les protocoles portent leurs défauts en extension**, pour que se conformer coûte le
  minimum. `Endpoint` n'exige que `service`, `path` et le type de réponse ; les huit
  autres membres ont un défaut.
- **Deux formes coexistent quand les deux ont du sens** : un type par cas quand il a une
  identité (`SendFeedback`), une forme générique réglable au point d'appel quand il n'en a
  pas (`Callable`).

Un test le vérifie explicitement à chaque fois : surcharger un réglage et constater que les
autres défauts tiennent.

## Concurrence

Swift 6 strict, **zéro warning de concurrence**. Un warning de concurrence est un bug
qui n'a pas encore eu lieu.

- **Store** : `@MainActor @Observable final class`, `static let shared`. C'est lui qui
  publie l'état vers SwiftUI, il vit donc sur le main actor.
- **Backends et tout ce qui fait de l'I/O** : `actor`. L'isolation est la protection par
  défaut.
- **État partagé synchrone et non isolé** : `Mutex` (`import Synchronization`). Jamais
  `NSLock`, jamais une `DispatchQueue` de sérialisation, jamais `@unchecked Sendable`
  sans un commentaire qui justifie précisément l'invariant tenu à la main.
- Tout ce qui franchit une frontière d'isolation est `Sendable`. Préférer des `struct`
  de valeurs immuables aux `class`.
- Les modules restent **`nonisolated` par défaut** (pas de `defaultIsolation: .MainActor`) :
  une brique ne décide pas de l'isolation de l'app qui la consomme. Seul le store est
  `@MainActor`, et c'est un choix assumé.
- Pas de `Task { }` détachée pour masquer un appel asynchrone derrière une API synchrone.
  L'`async` remonte jusqu'à l'appelant ; c'est lui qui décide où l'attendre.
- Pas de `Task.sleep` comme moyen de synchronisation, ni en code ni en test.

## Erreurs

- Tout ce qui peut échouer est `async throws`. **Pas** d'optionnel qui masque une erreur,
  pas de `try?` qui avale, pas de valeur par défaut silencieuse en cas d'échec.
- **Typed throws** (`throws(PersistenceError)`) dès que le domaine d'erreur est fermé —
  c'est-à-dire presque partout ici. Ça met le contrat d'erreur dans la signature.
- Une erreur par module : `enum PersistenceError: Error, Equatable, Sendable`. Elle porte
  le **contexte** (la clé, le backend, l'opération), jamais un `NSError` brut remonté tel
  quel. Une erreur qu'on ne peut pas diagnostiquer sans debugger est une erreur ratée.
- Les erreurs des couches basses sont **traduites** en remontant, pas propagées telles
  quelles : le store ne doit jamais laisser fuir un `CocoaError` de `FileManager`.

## Nommage — deux collisions à éviter

**Jamais de membre statique nommé `none`.** En position optionnelle, `.none` désigne
`Optional.none` et le compilateur le choisit **en silence** : une politique qu'on croit
désactivée redevient celle par défaut, sans erreur ni warning. Utiliser `disabled`, `off`,
ou un nom du domaine.

**Vérifier les noms contre les SDK que l'app importera.** `FirestoreQuery` et `WriteBatch`
existent déjà dans `FirebaseFirestore` : une app important les deux modules aurait eu une
ambiguïté à chaque usage. D'où `DocumentQuery` et `DocumentBatch`. Le réflexe avant de
nommer un type public : `grep` dans le SDK concerné.

## Visibilité

La surface publique est un engagement. On ne l'élargit pas « au cas où ».

- `public` : le store, les protocoles de contrat, les types de valeur, le type d'erreur.
- Tout le reste est `internal`. Les implémentations concrètes de backend le sont aussi,
  sauf besoin explicite d'injection depuis l'app.
- Les tests utilisent `@testable import`, ce qui n'est pas une raison de rendre public.
- Docs `///` obligatoires sur **tout** ce qui est `public` : ce que ça fait, ce que ça
  jette, et les conditions d'erreur.

## Tests

- Swift Testing. `Tests/SU<Nom>Tests/`, un fichier par type testé.
- Chaque couche est testée **derrière son protocole**, avec un double en mémoire de la
  couche inférieure. Un test de store qui touche le disque teste la mauvaise chose.
- Les tests de comportement sont **paramétrés sur les backends** : le même scénario doit
  passer à l'identique sur `UserDefaults`, sur JSON, et sur les backends futurs. C'est ce
  qui garantit qu'ils sont réellement interchangeables.
- Aucune écriture hors sandbox de test : `FileManager.default.temporaryDirectory` avec
  nettoyage systématique, et un `suiteName` dédié pour `UserDefaults` (jamais
  `.standard`).
- Nommer le test par le **comportement attendu**, pas par la fonction appelée.
  `@Test("relire une clé absente renvoie la valeur par défaut")`, pas `testLoad()`.
- Couvrir d'abord : round-trip, clé absente, données corrompues, écritures concurrentes.

## Style

- Un type public par fichier, le fichier porte le nom du type.
- Pas de commentaire qui paraphrase le code. Un commentaire explique un **pourquoi**
  non évident, ou n'existe pas.
- Pas de `// MARK:` décoratif dans un fichier de 40 lignes.
- Pas d'abréviation dans les noms publics.

## Arborescence

```
swift-utils/
├── Package.swift
├── CLAUDE.md
├── README.md
├── Sources/
│   ├── SUPersistence/
│   │   ├── Store/ Repository/ Coding/ Backend/
│   └── SUNetworking/
│       ├── Store/ Client/ Middleware/ Transport/ Endpoint/ Policy/
└── Tests/
    ├── SUPersistenceTests/
    └── SUNetworkingTests/
```

## Intégration dans une app

La dépendance est **toujours déclarée par URL remote** dans le projet consommateur
(`https://github.com/ffondacci/swift-utils.git`). Jamais de `XCLocalSwiftPackageReference`
avec un chemin `../../` dans le `pbxproj` : ça rend le projet non portable (CI, autre
machine) et ça fige un chemin sur le disque de Florent.

L'édition en direct passe par un **workspace de développement**, à la racine de `repos/` :

```
repos/swift-utils-dev.xcworkspace     ← non versionné, artefact local
   ├── group:swift-utils              ← le package, en local
   ├── group:lensy/Lensy/Lensy.xcodeproj
   └── …                              ← les autres apps consommatrices
```

La présence du dossier dans le workspace **override** la dépendance remote pour ce
workspace. Ce qui donne deux modes :

- **Workspace ouvert** → build sur le working tree, édition live, aucun commit nécessaire,
  et plusieurs apps consommatrices voient les mêmes modifications en même temps.
- **Projet app ouvert seul** → build sur le tag publié. C'est le test de non-régression :
  l'app tient-elle encore sur la version publiée ?

Deux contraintes Xcode à connaître, elles ont la même cause — Xcode range un document
`.swiftpm/xcode/package.xcworkspace` **dans** le dossier du package, et un `.xcodeproj`
ne peut appartenir qu'à un workspace ouvert à la fois :

- Ne pas ouvrir un projet app en même temps que le workspace qui le contient.
- Ne pas ouvrir le package en standalone (`open Package.swift`) en même temps que le
  workspace. Pour travailler le package seul et lancer ses tests, fermer le workspace.

## Ajouter un utilitaire

1. `Sources/SU<Nom>/`, découpé en couches comme ci-dessus.
2. Un produit `.library(name: "SU<Nom>")` et sa target dans `Package.swift`.
3. Un store `@MainActor @Observable`, seule surface publique d'usage. Avec
   `static let shared` **si et seulement si** une configuration par défaut a du sens sans
   rien savoir de l'app.
4. `Tests/SU<Nom>Tests/`.
5. Une section dans le `README.md` : à quoi ça sert, comment on l'injecte, un exemple.
6. Une page de wiki dédiée, plus la ligne correspondante dans `Home`.

Un utilitaire ne dépend d'un autre utilitaire que si Florent l'a validé explicitement.
Par défaut, les modules sont indépendants.

**`SULogger` est l'exception, et la seule.** C'est une brique transverse — tracer concerne
tout le monde — et elle n'a aucune dépendance externe, donc l'importer ne coûte rien à
personne. Les autres modules en dépendent et tracent directement, au lieu d'obliger chaque
app à recâbler un protocole de journal par module.

L'inverse reste interdit : `SULogger` ne dépend de rien.

## Le trait n'élague que si rien n'est épinglé

`Package.resolved` **n'est pas versionné**, et ce n'est pas un oubli.

Une bibliothèque n'a pas à le committer — celui d'un consommateur fait foi de toute façon.
Mais surtout : s'il est présent après un build `--traits Firebase`, il épingle les quatorze
paquets du SDK, et **SwiftPM les retélécharge même pour un build sans le trait**.

Mesuré sur ce dépôt :

| État de départ | checkouts |
|---|---|
| vierge | 0 |
| `Package.resolved` issu d'un build avec trait | 14 |

Donc : ne jamais le committer, et si un chiffre de checkouts surprend, commencer par
`rm -rf .build Package.resolved`.

## Pièges connus du compilateur

**Swift 6.3.3 plante en abaissement SIL** sur une closure à typed throws qui **retourne**
une closure à typed throws — typiquement la composition d'une chaîne de middlewares par
`reduce`. Le message est un `signal 5`, sans ligne fautive utile.

Contournement en place dans `SUNetworking/Client/APIClient.swift` : un type `Link`
explicite qui porte l'index du maillon courant, au lieu de closures imbriquées. Même
comportement, un seul niveau de closure.

Si une composition de closures typées plante sans raison apparente, c'est probablement ça.

## Wiki — à mettre à jour avec le code

Le wiki GitHub est la documentation de référence du dépôt : le `README` reste court et
renvoie vers lui. Il vit dans un **dépôt git distinct** :

```bash
git clone https://github.com/ffondacci/swift-utils.wiki.git
```

**Il se met à jour dans le même mouvement que le code, jamais plus tard.** Une doc qui
décrit une version antérieure est pire qu'une doc absente : elle fait perdre du temps avec
de la confiance en prime. Concrètement, avant de considérer un changement terminé :

| Ce qui change | La page à reprendre |
|---|---|
| API publique ajoutée, renommée, retirée | `SUPersistence` (guide d'usage) |
| décision d'architecture, nouveau backend | `SUPersistence-Architecture` |
| règle d'écriture | `Conventions` **et** ce fichier |
| workflow, outillage, publication | `Developpement` |
| nouveau module | une page dédiée + une ligne dans `Home` |
| nouvelle app consommatrice | le tableau de `Home` |

Pages existantes : `Home`, `_Sidebar`, `SUPersistence`, `SUPersistence-Architecture`,
`Conventions`, `Developpement`.

Le contenu des pages est en **français**, comme le `README` et ce fichier. Les messages de
commit du wiki sont en **anglais**, comme partout dans git. La branche du dépôt wiki est
`master`, pas `main`.

## Environnement — le linker

`swift build` et `swift test` échouent en édition de liens avec :

```
ld: unknown option: -no_warn_duplicate_libraries
```

Cause : Anaconda place un `ld64-711` obsolète dans `/opt/homebrew/anaconda3/bin`, qui
passe **avant** celui d'Apple dans le `PATH`. Ce n'est pas un problème du package — le
code compile, c'est le lien qui casse.

Contournement, à faire dans le shell avant de lancer les commandes :

```bash
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.swiftly/bin"
```

Xcode n'est pas touché : il utilise son propre linker et ne lit pas ce `PATH`.

## Git

Les règles globales s'appliquent : **tout ce qui vit dans git s'écrit en anglais** —
messages de commit, noms de branches, titres et descriptions de MR, tags. Les échanges
avec Florent restent en français.

### Versions — ne pas tagger pour rien

**Un tag se pose quand un consommateur en a besoin, pas à chaque fonctionnalité.**

Tant qu'aucune app ne consomme le paquet, une « rupture » est théorique : il n'y a rien à
casser. Trois majeures en une journée pour un paquet que personne n'a encore intégré, c'est
du bruit — ça donne l'illusion d'une histoire de versions qui n'existe pas.

La règle :

- Le travail s'accumule sur `develop`, sans tag.
- On tague **le jour où une app doit résoudre la dépendance**, ou quand Florent le demande.
- À partir de là seulement, SemVer strict : une rupture d'API ou de format de données est
  une majeure, parce qu'il y a désormais quelqu'un à casser.

### Branches

| Branche | Rôle |
|---|---|
| `main` | Les versions publiées. Chaque commit y porte un tag, et c'est ce que les apps consomment. |
| `develop` | Le travail en cours. C'est la branche par défaut du quotidien. |

On commite **directement sur `develop`**, sans branche de feature ni PR : Florent est seul
sur le dépôt, une PR n'apporte aucune relecture.

`main` ne bouge qu'au moment de publier : on y merge `develop`, on tague, on pousse les
deux. Ça garde `main` toujours installable — une app qui résout par tag ne voit jamais un
état intermédiaire.

```bash
git checkout main && git merge --ff-only develop
git tag -a 1.1.0 -m "…"
git push origin main develop --tags
git checkout develop
```

Le dépôt wiki, lui, n'a qu'une branche et elle s'appelle `master`.
