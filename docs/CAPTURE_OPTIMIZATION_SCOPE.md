# Scope: maximising the single front-burst thumbprint (capture-side)

Strategy locked to **one front-print view** (multi-angle reconstruction retired
— four rigorous NO-GOs; combining views breaks ridge continuity). This scopes
every remaining lever to squeeze quality out of that single capture.

## The one rule that governs all of it

NFIQ downscales every print to **500×500**. So the score is set by **how
sharp and high-contrast the ridges are once the pad fills that 500×500** — NOT
by megapixels. Consequences:
- **Optical sharpness / real resolving power at the working distance = the
  lever.** (Unlike digital super-resolution, which the 500×500 discards.)
- A "low-MP" camera (8/12MP) is **not** disqualified — if it resolves ridges
  more sharply, it wins. MP count above what fills 500×500 is irrelevant.
- The pad **must fill the frame** (framing/zoom) so those sharp ridges occupy
  the scored 500×500.

## Device reality — Doogee S118 (original), 3 rear cameras

| Camera | Sensor | Role today | Fingerprint potential |
|--------|--------|-----------|------------------------|
| 50MP f/1.8 wide, PDAF | Samsung | **in use** | best AF + sensor; but a main-cam **min focus distance** (~8–10cm typical) caps how close/detailed it gets |
| 12MP f/1.8 "night vision" + **2 IR LEDs** | Sony-class | unused | **controlled IR illumination** — ambient-independent, scanner-like ridge contrast. Highest-upside unknown |
| 8MP f/2.2 ultrawide 121° | — | unused | short focal length may focus **closer** (macro-ish) → more ridge detail; but heavy edge distortion + weaker optics |

Everything below is gated on **what Flutter can actually open** — see Phase 0.

---

## Lever A — Multi-camera selection ("camera oscillation") — your idea #1

**Do NOT pick a camera blind — capture from each accessible one and let ridge
sharpness decide.** Exactly the max-variant philosophy that's working on the
backend, applied to hardware: worst case the main camera wins and nothing
regresses.

- Capture a short burst from each accessible rear camera at the same pad framing.
- Score each with the server-side ridge-band energy probe (already in
  `afis_print._ridge_energy`).
- Keep the sharpest as the superprint source; log which camera won per capture
  so we learn the device-specific winner.

**Feasibility caveat (must probe):** Flutter's `camera` plugin exposes only the
cameras the device's Camera2 HAL advertises via `availableCameras()`. Flagships
often hide macro/tele behind a logical camera; **rugged phones like Doogee more
often expose them as separate IDs** — but this is unknown until probed. If a
camera isn't exposed, reaching it needs a platform-channel Camera2 physical-ID
path (larger effort) — decide after Phase 0.

## Lever B — Working distance, magnification, focus — your idea #2

"Closer = richer detail" is **true only down to the camera's minimum focus
distance** — past that it goes blurry, not sharper. So the levers are:

1. **Distance guidance:** the reticle frames the pad; add a **distance target**
   so the user holds at the exact min-focus distance where the pad fills the
   frame AND is in sharp focus. Too close is the current silent failure mode.
2. **Zoom-to-fill:** if the pad still under-fills at min-focus distance, apply
   sensor **crop-zoom** so the pad occupies more real sensor pixels (more
   effective ridge resolution) — genuine gain until you hit the sensor's own
   resolving limit.
3. **Focus bracketing:** capture the burst across a few focus positions and keep
   the sharpest. Focus is the single biggest sharpness variable; bracketing
   removes the "autofocus settled slightly wrong" failure the still-sharpness
   gate can only reject, not fix.
4. **Macro path:** test the ultrawide's close-focus, and — for a rugged/
   industrial product — a **clip-on macro lens (~$10)** is a legitimate
   accessory that can dramatically out-resolve any built-in lens at pad range.
   Cheap to test, potentially the biggest single-lever jump.

## Lever C — Capture format (stop throwing ridge detail away)

1. **Disable computational photography / "AI" beautification.** The 50MP "AI"
   pipeline may smooth/denoise skin — which *erases fine ridges*. Capture in the
   most "raw"/pro mode the camera exposes; measure ridge energy with AI on vs off.
2. **RAW/DNG capture** where supported: JPEG compression damages exactly the
   high-frequency ridge band. RAW preserves it. Today the app uploads a JPEG /
   Y-plane; test RAW → ridge-energy delta.
3. **Full-res, un-binned** capture if it resolves ridges better than the binned
   default (verify — binning can also *reduce noise*; empirical).

## Lever D — IR illumination (ties A + C together)

The night-vision camera's **2 IR LEDs give controlled, ambient-independent
illumination** — the closest thing on this phone to a real biometric scanner's
light source. Two things to test:
1. IR-camera capture as its own illumination "source" in the existing
   flash/ambient fusion (which already gives +12 NFIQ) → a potential 3rd fused
   channel.
2. IR as the *primary* capture in poor ambient light (where NFIQ currently
   halves) — it removes the lighting dependency entirely.

---

## Prioritised plan

**Phase 0 — Device camera probe (cheap, decisive, ~½ day + one APK).**
Ship a hidden diagnostic screen that:
- enumerates `availableCameras()` + each camera's capabilities (min focus
  distance, focal length, RAW support, max resolution, exposure/zoom ranges);
- captures one pad frame from **every** accessible rear camera (+ IR toggled);
- uploads them tagged.
Then we measure ridge-band energy per camera on real thumb captures and **know
exactly** which cameras are reachable and which resolves ridges best — no
guessing. **Everything else is gated on this.**

**Phase 1 — Act on the probe (per findings):**
- Wire capture-from-best-camera (Lever A) + IR source (Lever D) as the front
  source, scored by ridge energy (non-regressing).
- Add focus bracketing + distance target (Lever B 1–3).

**Phase 2 — Format + hardware:**
- RAW capture + disable-AI mode (Lever C); A/B on ridge energy.
- Test ultrawide macro-focus and a clip-on macro lens (Lever B 4).

## Recommendation

**Build Phase 0 first — it's the single highest-value half-day here**, because
it converts three guesses (which cameras are reachable, does the ultrawide focus
close, does IR help) into measured facts, and it can't regress anything (it's a
diagnostic). My ranked bets for where the real gain is:
1. **IR night-vision illumination** — ambient-independent, scanner-like; biggest
   upside, most novel.
2. **Focus bracketing on the main camera** — focus is the #1 sharpness variable;
   pure software, no hardware dependency.
3. **Clip-on macro lens** — if you'll ship a rugged accessory anyway, this
   out-resolves everything for ~$10.
4. Ultrawide/alt-camera selection — real but bounded by those sensors' quality.

All of this is **capture-side and NFIQ-honest** (optical sharpness inside the
500×500), and every item is structured as a non-regressing max-variant or an
opt-in mode. None of it touches the retired multi-angle path. In parallel, the
**learned restoration model still owns the biggest single jump** — this scope
maximises the *input* that model will later restore, so the two compound.
