# Scope: small-roll pad-flattening for NFIQ (continuous small-baseline chaining)

**Goal:** sharpen the thumb pad's LEFT/RIGHT edges — which curve away from a
face-on camera and are always soft in a single shot — by compositing views from
a *small* continuous roll, WITHOUT extending coverage beyond the pad (which
would dilute NFIQ's fixed 500×500). North star = NFIQ.

## The hypothesis is mechanically validated — but the NFIQ ceiling is real

Compositing slightly-rolled views (±6–14°) into the pad edge bands raised **edge
ridge coherence +33–69%** on real captures (indoor L+45%/R+33%, sunlight
L+69%/R+55%). So the extra detail genuinely exists and is recoverable.

**BUT** the same composite, scored end-to-end, moved NFIQ only **+1.5** (latest
capture; ~0 on the others). Why the gap: NFIQ scores the whole 500×500, and the
edge bands are a *minority* of pad area — the already-sharp center dominates the
number. So a big local edge gain becomes a small global score gain.

This bounds the prize: **realistically single-digit NFIQ**, not a jump to 80.
Worth doing, but not the thing that gets us to 80 (that's the learned model).

## Why a dense continuous roll could beat the discrete +1.5

The +1.5 came from a handful of *discrete* binned side frames. A continuous
small roll would improve three things:
1. **Denser edge-angle coverage** — every edge column gets a view where it's
   near-face-on, not just whatever the 8 discrete holds happened to catch.
2. **Better registration** — <2° neighbour steps mean near-zero foreshortening
   between adjacent frames, so homographies are tight (COLMAP-grade SfM not
   needed).
3. **Per-segment tangent-plane blending** — flatten each edge on its own local
   plane instead of one global warp.

Unknown until tested: how much of the edge-coherence gain survives into NFIQ
once blended. That's the go/no-go question.

## Capture protocol (the required app change)

New "small-roll" mode in the oscillating controller family:
- **Motion:** one slow continuous roll of the pad, ~**±15° total** (NOT the
  current ±20–36° discrete holds), ~2–3 s.
- **Frames:** preview stream at max fps (≥30), each tagged with per-frame IMU
  roll — no burst holds needed (chaining wants density, not per-hold ISP
  stills), though 1–2 face-on ISP anchors help the center.
- **Both illuminations** still alternate (fusion stays the front-pad lever).
- Upload the dense roll (already have retry + downscale plumbing).

## Backend algorithm

1. Order roll frames by IMU angle; pick the sharpest near-0° as anchor.
2. Chain neighbour→neighbour homographies outward (±<2° steps), light global
   drift constraint.
3. For each pad column, select/blend the view where that column is most
   face-on (max ridge coherence), warped into the anchor's frame.
4. **Tight-crop to the pad** (never let it shrink below frame-fill — that's the
   NFIQ-killer) → existing enhance → score as a **max-variant** (can't regress).

## Recommended plan — cheap gate first

**Phase 0 (½–1 day, no app change): prove the ceiling.**
Hand-collect 2–3 continuous small-roll videos on the Doogee (just screen-record
or a normal video of the roll), run the chaining offline, score NFIQ vs the
current best. **Go/no-go:** if it doesn't clear roughly +3–5 NFIQ over today's
pipeline, stop — the edge-minority ceiling isn't worth a capture-flow project.

**Phase 1 (only if Phase 0 passes, ~3–5 days):** build the small-roll capture
mode + backend chaining variant; validate on real sessions.

## My recommendation

**Do Phase 0, gate hard.** The mechanism is real (+45–69% edge coherence) and
NFIQ-compatible (pad stays frame-filling), so it's not a dead end like
whole-print reconstruction. But the measured discrete payoff (+1.5) and the
edge-minority ceiling say the upside is single-digit — good, not
transformational. Spend a day proving the dense-roll ceiling before committing
to the app change. In parallel, the **learned restoration model remains the
real path to 80** — it improves the whole pad, center included, so it isn't
bounded by the edge-minority problem. Prioritise the beta dataset for that.
