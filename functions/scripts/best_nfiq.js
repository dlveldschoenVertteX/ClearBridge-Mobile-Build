// One-off diagnostic, NOT a deployed Cloud Function -- run manually via
// .github/workflows/best-nfiq.yml (workflow_dispatch only). Finds the
// single highest real nfiq2Score across every scored capture in the live
// `captures` collection and prints its key metadata. Read-only, no images
// involved -- output goes only to that workflow run's own private GitHub
// Actions log.
//
// Usage:
//   GOOGLE_APPLICATION_CREDENTIALS=/tmp/sa.json node scripts/best_nfiq.js

const admin = require("firebase-admin");

admin.initializeApp();

async function main() {
  const db = admin.firestore();
  const snap = await db.collection("captures")
    .where("status", "==", "scored")
    .get();

  let best = null;
  snap.forEach((doc) => {
    const d = doc.data();
    if (typeof d.nfiq2Score === "number" && (!best || d.nfiq2Score > best.nfiq2Score)) {
      best = {
        id: doc.id,
        nfiq2Score: d.nfiq2Score,
        nfiqPass: d.nfiqPass,
        userId: d.userId,
        henryClass: d.henryClass,
        captureMode: d.captureMode,
        afisSource: (d.superprintParams && d.superprintParams.afisSource) || d.afisSource,
        createdAt: d.createdAt && d.createdAt.toDate ? d.createdAt.toDate().toISOString() : null,
      };
    }
  });

  if (!best) {
    console.log(`No scored captures with a real nfiq2Score found (${snap.size} scored docs checked).`);
    return;
  }
  console.log(`Checked ${snap.size} scored captures. Best real NFIQ2 score:`);
  console.log(JSON.stringify(best, null, 2));
}

main().catch((e) => {
  console.error("best_nfiq failed:", e);
  process.exit(1);
});
