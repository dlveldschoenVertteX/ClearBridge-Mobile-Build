# fusion_capture — three-phase fusion capture (research build)

**Standalone app. Nothing that ships depends on it. `rm -rf fusion_capture/`
plus removing the `build-fusion-capture` CI job reverts it completely.**

## The session

One continuous capture, three phases, one persistent guide:

| phase | what it does | why |
|---|---|---|
| **1 · Main** | hold-to-lock, then 8-shot alternating ambient/flash burst | the proven front_only_v1 flow; the anchor every other phase registers against (measured highest corroboration, 84.3%, and lowest unmatched rate) |
| **2 · Edges** | ~11° tilt left / tip / right, ambient+flash pair each | **measured**: a −11.8° frame contributed **107 new edge minutiae** a face-on capture never sees, against a face-on CONTROL frame's **4** |
| **3 · Texture** | guide translated left/centre/right, ambient+flash pair each | sweep had the highest unique-new-coverage of any source family (16.6%) |

## Design decisions that are evidence-driven, not preference

**Each phase emits independent, complete candidates. Nothing is blended
on-device.** Four separate image-space fusion attempts in this project
(sweep cross-zone mosaic, field-domain orientation fusion, `focusZoneSplice`,
zone reduction) all lost to a single un-fused candidate on real matchability.
Compositing frames of non-rigid skin manufactures spurious minutiae at every
seam, and minutiae matchers punish those heavily. Any actual fusion happens
later, offline, in **minutiae space** — see `fusion_brain/`.

**~11°, not ~17°.** More tilt is not better: −11.8° produced *more* new edge
coverage than −17.0° (107 vs 87) on real multi-angle data. Past some angle,
perspective distortion costs more than the extra revealed surface.

**The focus-zone bracket is deliberately absent.** It shares framing with the
main burst (only the AF/AE target moves), so it cannot reveal new pad
surface — measured median 6 new minutiae, for ~15–18s of real capture time.
That time is spent on tilt instead, which measured 15-25x better.

**Every station captures an ambient+flash PAIR.** Flash-minus-ambient is what
lets the backend separate near-camera skin from background (torch falloff
~ distance²). Without a pair, a candidate can only ever be masked by the bare
geometric guide with zero awareness of what is actually in frame.

**The guide→still transform is ported verbatim, not re-derived.** A naive
rotation ignores the `BoxFit.cover` crop/scale — exactly the bug that made
real captures score single digits until it was found and fixed (NFIQ2 → 72).

## Isolation — code AND data

**Code.** Own app id (`com.clearbridge.fusion`, installs alongside the
others), own pubspec, own gradle, own CI job. `packages/mac_capture` is a
**read-only** dependency — zero shared files modified. Nothing outside
`fusion_capture/` imports anything from it.

**Data — the part that actually mattered.** An earlier draft wrote
`captureMode: 'front_only_v1'` so the deployed backend would score phase 1
for free. That was a real contamination hazard and was removed: this project
makes decisions from historical capture stats (the 116-capture variant
win-rate study, the mask-vs-matchability sweeps), and every one of those
filters on `captureMode == 'front_only_v1'`. Experimental captures landing in
that population would have skewed the very baseline this experiment is
measured against.

Captures are therefore written as:

- `captureMode: 'fusion_v1'` — cannot be picked up by any existing
  production query
- `isExperiment: true` — explicit intent for anything written later
- `fusionVersion: 'fusion_v1'`
- `tiltShots[]`, `sweepShots[]`, `fusionGuideRegions{}`, `fusionDebug{}`

`fusion_brain/`'s own analysis also skips any doc carrying `isExperiment` or
`fusionVersion`, so this experiment cannot contaminate even its own
baselines.

**The production Cloud Function is not called** (`_triggerProductionBackend
= false`). With `captureMode: 'fusion_v1'` the backend would not take its
front_only_v1 path anyway — it would fall through to `_download_best_frames`
and mix phase-1, tilt and sweep frames into one undifferentiated set.
Scoring happens offline in `fusion_brain/`, which already runs the real
production `afis_print.generate()`, so nothing is lost.

**Consequence to expect:** these captures stay at `status: 'pending'`
forever and never get an NFIQ2 score in the app. That is the correct
behaviour for an isolated experiment — the score comes from offline
analysis, not from production.

## Honest status

- **Not device-tested.** No Flutter toolchain in the authoring sandbox, so
  this is written-and-verified-against-the-shared-package, not run. CI
  `flutter analyze` is the first real check.
- **Session is materially longer** than production's single burst (roughly
  60s vs ~20s). The three-segment stepper shows all three phases from the
  start so that length is never a mid-capture surprise.
- **Tilt angle is intent, not measurement.** Nothing on-device can observe
  how far a *finger* tilted (sensors see the phone). The achieved angle is
  only recoverable offline by registering against the face-on anchor.
- Phase toggles (`_frontEnabled` / `_tiltEnabled` / `_sweepEnabled`) exist so
  any phase can be isolated for A/B.
