// One-off diagnostic, NOT a deployed Cloud Function -- run manually via
// .github/workflows/best-superprint.yml (workflow_dispatch only). Finds
// the top-N real scored captures by nfiq2Score and prints a short-lived
// signed read URL for each one's delivered superprint_afis.png (Storage
// path captures/{userId}/{captureId}/superprint_afis.png, per
// main.py's own _save_afis_print). Does NOT pick "the best" itself --
// per this project's own standing prime directive (NFIQ2 alone is
// foolable; real ridge continuity has to be checked visually/by a real
// matcher, never assumed from the score alone), the actual pick is made
// by inspecting the candidate images directly, outside this script.
// Read-only, no writes. Output (URLs only, no image bytes) goes only to
// the triggering workflow run's own private Actions log.
//
// Usage:
//   GOOGLE_APPLICATION_CREDENTIALS=/tmp/sa.json node scripts/best_superprint.js [N]

const admin = require("firebase-admin");

admin.initializeApp();

const TOP_N = parseInt(process.argv[2], 10) || 8;
const SIGNED_URL_EXPIRES_MIN = 30;

async function main() {
  const db = admin.firestore();
  const bucket = admin.storage().bucket();

  const snap = await db.collection("captures")
    .where("status", "==", "scored")
    .get();

  const candidates = [];
  snap.forEach((doc) => {
    const d = doc.data();
    if (typeof d.nfiq2Score === "number") {
      candidates.push({
        id: doc.id,
        nfiq2Score: d.nfiq2Score,
        nfiqPass: d.nfiqPass,
        userId: d.userId,
        henryClass: d.henryClass,
        captureMode: d.captureMode,
        afisSource: (d.superprintParams && d.superprintParams.afisSource) || d.afisSource,
        createdAt: d.createdAt && d.createdAt.toDate ? d.createdAt.toDate().toISOString() : null,
        path: d.superprintPath || `captures/${d.userId}/${doc.id}/superprint_afis.png`,
      });
    }
  });

  candidates.sort((a, b) => b.nfiq2Score - a.nfiq2Score);
  const top = candidates.slice(0, TOP_N);

  console.log(`${candidates.length} scored captures with a real nfiq2Score. Top ${top.length} by score:`);
  for (const c of top) {
    let url = null;
    try {
      const [exists] = await bucket.file(c.path).exists();
      if (exists) {
        const [signed] = await bucket.file(c.path).getSignedUrl({
          action: "read",
          expires: Date.now() + SIGNED_URL_EXPIRES_MIN * 60 * 1000,
        });
        url = signed;
      }
    } catch (e) {
      url = `ERROR generating signed URL: ${e.message}`;
    }
    console.log(JSON.stringify({...c, superprintUrl: url ?? "(file not found in Storage)"}, null, 2));
  }
}

main().catch((e) => {
  console.error("best_superprint failed:", e);
  process.exit(1);
});
