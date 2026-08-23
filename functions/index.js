// nodejs-functions codebase (see firebase.json: {"source": "functions",
// "codebase": "nodejs-functions", "runtime": "nodejs20"}) -- referenced by
// that config since the project's early scaffold but never actually
// populated with real source before this file (confirmed empty on this
// branch, 2026-08-23, before this commit -- `functions/` had no index.js
// and no package.json at all). Deploy with:
//   firebase deploy --only functions:nodejs-functions --project clearbridge-dc699
//
// bootstrapFirstAdmin: the server-side half of landing/admin_panel/'s
// "create the admin account on first launch" flow. A client can create a
// real Firebase Auth account entirely on its own
// (createUserWithEmailAndPassword), but custom claims -- the `admin: true`
// claim router_service.dart's own adminClaimProvider already checks in the
// Flutter app, and this same admin panel's own login gate checks too --
// can ONLY be set server-side, via the Admin SDK. That is a real,
// load-bearing Firebase security boundary, not an arbitrary restriction:
// if a client SDK could grant its own custom claims, any signed-in user
// could self-promote to admin, which would make the whole claim-based
// gate meaningless.
//
// This function is deliberately narrow: it grants the claim to whoever
// calls it, but ONLY when no account anywhere already carries it -- so it
// can only ever succeed once, for the genuine first admin. Every call
// after that (by design, not by luck) hits the already-exists refusal
// below and grants nothing, regardless of who calls it or how many times.

const {onCall, HttpsError} = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

admin.initializeApp();

exports.bootstrapFirstAdmin = onCall({region: "africa-south1"}, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign in first.");
  }
  const uid = request.auth.uid;

  // Page through every user account looking for an EXISTING admin claim.
  // listUsers() returns up to 1000 accounts per page; this project's own
  // real user counts (on the order of a few hundred, not thousands, per
  // its own history) fit in one or a small handful of pages, so a full
  // scan on every bootstrap attempt is cheap -- and, more importantly,
  // correct: there is no separate "has this project been bootstrapped"
  // flag to fall out of sync with reality. The live account list IS the
  // source of truth for whether an admin already exists.
  let pageToken;
  do {
    const page = await admin.auth().listUsers(1000, pageToken);
    if (page.users.some((u) => u.customClaims && u.customClaims.admin === true)) {
      throw new HttpsError(
          "already-exists",
          "An admin account already exists. Ask an existing admin for access instead.",
      );
    }
    pageToken = page.pageToken;
  } while (pageToken);

  await admin.auth().setCustomUserClaims(uid, {admin: true});
  return {ok: true};
});
