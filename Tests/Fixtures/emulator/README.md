# Banc d'essai émulateur

Trois Cloud Functions `onCall` jetables, pour vérifier que `SUNetworking` parle bien le
format `onCall` — et non ce que j'ai cru comprendre du format `onCall`.

Aucun projet Firebase n'existe derrière. L'identifiant `demo-swift-utils` est reconnu par
l'émulateur comme factice : rien n'est créé, aucun compte n'est sollicité, et rien ne peut
joindre la production.

## Lancer

```bash
cd Tests/Fixtures/emulator/functions && npm install     # une fois
cd Tests/Fixtures/emulator
firebase emulators:start --only functions --project demo-swift-utils
```

Puis, dans une autre fenêtre :

```bash
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.swiftly/bin"
SU_EMULATOR=1 swift test --filter CallableEmulatorTests
```

Sans `SU_EMULATOR=1`, ces tests **se sautent tout seuls** : `swift test` reste vert sur une
machine où l'émulateur ne tourne pas, CI comprise.

## Les fonctions

| Fonction | Ce qu'elle fait |
|---|---|
| `echoPayload` | rend ce qu'on lui envoie, pour vérifier l'enveloppe dans les deux sens |
| `returnsNothing` | ne rend rien — le cas `{"result": null}` |
| `failsWithError` | lève une `HttpsError`, pour voir la forme réelle d'une erreur |
| `requiresAuth` | refuse sans jeton, pour voir la forme réelle d'un refus |
