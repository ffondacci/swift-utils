import { onCall, HttpsError } from "firebase-functions/v2/https";

/// Rend ce qu'on lui a envoyé. Vérifie l'enveloppe dans les deux sens.
export const echoPayload = onCall((request) => {
  return { received: request.data ?? null, hadAuth: request.auth != null };
});

/// Ne rend rien. C'est le cas `{"result": null}`.
export const returnsNothing = onCall(() => {
  return;
});

/// Lève une erreur applicative, pour observer la forme réelle d'un échec.
export const failsWithError = onCall(() => {
  throw new HttpsError("permission-denied", "pas le droit", { reason: "test" });
});

/// Refuse sans jeton, pour observer la forme réelle d'un refus d'authentification.
export const requiresAuth = onCall((request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "jeton requis");
  }
  return { user: request.auth.uid };
});
