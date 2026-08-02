# Landing-page regeneration

The production landing page at [clearbridgeapp.co.za](https://clearbridgeapp.co.za)
is prerendered from a design-tool export (a `.dc.html` file + optional
`dc-import`'d component files + assets) so it renders instantly with no
framework/bundler runtime on the client.

To regenerate `landing/index.html` from a fresh design export:

1. Drop the export files into `scratchpad/landing_page_new/`:
   - `ClearBridge Landing.dc.html` (main page)
   - `ClearCoin Card.dc.html` (imported component)
   - `assets/*.png` (all referenced images)
2. `python3 scripts/landing/build_landing.py`
3. Copy the output:
   ```
   cp scratchpad/landing_page_new/index.html landing/index.html
   cp scratchpad/landing_page_new/assets/*.png landing/assets/
   ```
4. Commit `landing/` and push -- the `deploy-web` CI job in
   `.github/workflows/build.yml` deploys the site on every push.

The script:
- Strips `<x-dc>`, `<helmet>`, and `<dc-import>` wrappers
- Inlines any dc-imported components
- Replaces `{{ ... }}` template bindings with data-attribute markers plus a
  tiny vanilla-JS animator that reproduces the DCLogic Component's ticks
- Preserves the responsive/mobile CSS overrides from the current landing
  page (hand-tuned for real-device breakpoints -- don't re-derive)
- Rewires "Download The App" CTAs to the real APK URL served by Firebase
  Storage (see `deploy-web` in the CI workflow)
