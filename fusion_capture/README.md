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

## Backend contract: zero production changes

Captures are written with `captureMode: 'front_only_v1'` **on purpose**, so
the existing deployed backend processes phase 1 normally and yields a real
baseline score for free. The extra phases ride along in fields the backend
simply ignores:

- `fusionVersion: 'fusion_v1'` — what actually identifies these captures
- `tiltShots[]`, `sweepShots[]` — extra phase frames
- `fusionGuideRegions{}` — per-station still-space mask regions
- `fusionDebug{}` — per-phase timeouts, tilt target angles

`captureMode` is left alone precisely so nothing in production has to learn a
new mode. Offline analysis in `fusion_brain/` reads the extra fields.

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
