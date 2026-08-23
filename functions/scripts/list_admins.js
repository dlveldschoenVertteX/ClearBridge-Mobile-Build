// One-off diagnostic, NOT a deployed Cloud Function -- run manually via
// .github/workflows/list-admins.yml (workflow_dispatch only). Lists every
// Firebase Auth account that currently carries the `admin: true` custom
// claim, so a real, orphaned admin account (e.g. left over from the admin
// panel's earlier, pre-rebuild incarnation) can be identified without
// exposing a new public/callable endpoint. Output goes only to that
// workflow run's own GitHub Actions log, same private-to-collaborators
// visibility as every other deploy log in this repo -- never written
// anywhere public.
//
// Usage (mirrors deploy-admin-functions.yml's own credential handling):
//   GOOGLE_APPLICATION_CREDENTIALS=/tmp/sa.json node scripts/list_admins.js

const admin = require("firebase-admin");

admin.initializeApp();

async function main() {
  const found = [];
  let pageToken;
  do {
    const page = await admin.auth().listUsers(1000, pageToken);
    for (const u of page.users) {
      if (u.customClaims && u.customClaims.admin === true) {
        found.push({uid: u.uid, email: u.email || "(no email)", disabled: u.disabled});
      }
    }
    pageToken = page.pageToken;
  } while (pageToken);

  if (found.length === 0) {
    console.log("No account currently carries the admin claim.");
  } else {
    console.log(`${found.length} account(s) carry the admin claim:`);
    for (const f of found) {
      console.log(`  uid=${f.uid}  email=${f.email}  disabled=${f.disabled}`);
    }
  }
}

main().catch((e) => {
  console.error("list_admins failed:", e);
  process.exit(1);
});
