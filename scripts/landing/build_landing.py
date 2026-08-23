#!/usr/bin/env python3
"""
Convert the new .dc.html landing page + its dc-imported ClearCoin card into
a single, clean, production-ready index.html that:
  - drops the design-bundler runtime (<x-dc>, <helmet>, <dc-import>, support.js)
  - moves both files' <helmet> contents into a real <head>
  - inlines the ClearCoin card in place of its <dc-import> placeholder
  - preserves the responsive/mobile CSS overrides from the current landing/index.html
  - keeps all image paths pointing at ./assets/... (which we copy alongside)

Same design-system + inline-style discipline as the currently deployed page --
no framework, no build step, static-hosting friendly.
"""

import re
from pathlib import Path

HERE = Path(__file__).parent
SRC_MAIN = HERE / "ClearBridge Landing.dc.html"
SRC_CARD = HERE / "ClearCoin Card.dc.html"
CURRENT_LANDING = HERE.parent.parent / "landing" / "index.html"
OUT = HERE / "index.html"


def extract_between(src: str, start_tag: str, end_tag: str) -> str:
    """Return the inner text between the first <start_tag ...> and </end_tag>."""
    start_match = re.search(rf"<{start_tag}(?:\s[^>]*)?>", src)
    end_match = re.search(rf"</{end_tag}>", src)
    if not start_match or not end_match:
        raise RuntimeError(f"tags not found: {start_tag}/{end_tag}")
    return src[start_match.end():end_match.start()]


def extract_responsive_css(current: str) -> str:
    """Grab the top-of-file @media/mobile CSS block from the currently deployed page
    (which was hand-tuned for real-device breakpoints -- keep it, don't re-derive)."""
    match = re.search(
        r"<style>[^<]*?@media \(max-width: 768px\).*?</style>\s*<style>",
        current, re.DOTALL,
    )
    if not match:
        return ""
    # Return just the first <style> block (mobile overrides), not the main design CSS
    first_style = re.search(r"<style>(.*?)</style>", current, re.DOTALL)
    return first_style.group(1) if first_style else ""


def main() -> None:
    main_src = SRC_MAIN.read_text(encoding="utf-8")
    card_src = SRC_CARD.read_text(encoding="utf-8")
    current_src = CURRENT_LANDING.read_text(encoding="utf-8") if CURRENT_LANDING.exists() else ""

    def split(src: str) -> tuple[str, str]:
        # The helmet block lives INSIDE the x-dc wrapper -- grab helmet first,
        # then take only the content AFTER </helmet> as the real body.
        helmet = extract_between(src, "helmet", "helmet").strip()
        x_open = re.search(r"<x-dc(?:\s[^>]*)?>", src)
        x_close = re.search(r"</x-dc>", src)
        helmet_close = re.search(r"</helmet>", src)
        if not (x_open and x_close and helmet_close):
            raise RuntimeError("required tag not found")
        body = src[helmet_close.end():x_close.start()].strip()
        return helmet, body

    main_helmet, main_body = split(main_src)
    card_helmet, card_body = split(card_src)

    # The ClearCoin card was authored against a runtime templating layer
    # (`{{ count }}`, `{{ so0 }}` etc.) driven by a DCLogic component. We
    # stripped the framework runtime, so those placeholders would render
    # literally as text. Replace them with data-cc-* markers + initial
    # values and add a small vanilla-JS animator below that reproduces the
    # same 0->50 count-up + orbital band lighting the original DCLogic
    # Component did.
    for i in range(5):
        card_body = card_body.replace(
            f"stroke-opacity:{{{{ so{i} }}}};",
            f'stroke-opacity:0.07;" data-cc-band="{i}"',
        )
        # The above closed style="" one character early -- fold data-cc-band
        # back OUT of the style attribute and drop the resulting orphaned
        # `" data-cc-band="X"` suffix that ended up mid-style. This one
        # targeted replace handles the specific residue for each band.
        card_body = card_body.replace(
            f'stroke-opacity:0.07;" data-cc-band="{i}"transition:',
            f'stroke-opacity:0.07;transition:',
        )
    # Now add the data-cc-band attribute back onto each circle, using its
    # unique rotate() value as the anchor for the match (each band has a
    # different rotate angle -- see the source file lines 146-162).
    for i, angle in enumerate([-90, -18, 54, 126, 198]):
        card_body = card_body.replace(
            f'transform:rotate({angle}deg);transform-origin:90px 90px;" />',
            f'transform:rotate({angle}deg);transform-origin:90px 90px;" data-cc-band="{i}" />',
        )

    # Numeric count occurrences: two of them (main big number + right-column
    # balance). Replace both with a marker span.
    card_body = card_body.replace(
        ">{{ count }}<",
        ' data-cc-count>0<',
    )
    # ...and the standalone stroke-dashoffset attribute value.
    card_body = card_body.replace(
        'stroke-dashoffset="{{ dashoffset }}"',
        'stroke-dashoffset="465.10" data-cc-dashoffset',
    )

    # Vanilla-JS reimplementation of the DCLogic Component. Same cubic
    # ease-in-out, same 700ms initial delay, same target/duration/geometry.
    cc_animator = """
<script>
(function(){
  var start = null;
  var target = 50;
  var duration = 2100;
  var circ = 465.10;
  var maxCoins = 60;
  function ease(t){ return t<0.5 ? 4*t*t*t : 1 - Math.pow(-2*t+2, 3)/2; }
  function tick(now){
    if (!start) start = now;
    var p = Math.min((now - start) / duration, 1);
    var e = ease(p);
    var count = Math.round(e * target);
    var dashoffset = +(circ * (1 - e * target / maxCoins)).toFixed(2);
    document.querySelectorAll('[data-cc-count]').forEach(function(el){
      el.textContent = String(count);
    });
    var n = Math.min(Math.floor(count / 10), 5);
    document.querySelectorAll('[data-cc-band]').forEach(function(el){
      var i = +el.getAttribute('data-cc-band');
      el.style.strokeOpacity = (n > i) ? '1' : '0.07';
    });
    var dash = document.querySelector('[data-cc-dashoffset]');
    if (dash) dash.setAttribute('stroke-dashoffset', String(dashoffset));
    if (p < 1) requestAnimationFrame(tick);
  }
  function start_(){ setTimeout(function(){ requestAnimationFrame(tick); }, 700); }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start_);
  } else {
    start_();
  }
})();
</script>
"""
    card_body = card_body + "\n" + cc_animator.strip()

    # Inline the ClearCoin card in place of its <dc-import> tag. The tag has
    # style="width:390px; max-width:100%;" which we wrap around the card body
    # so the card sits in its intended slot.
    dc_import_pattern = re.compile(
        r'<dc-import\s+name="ClearCoin Card"[^>]*style="([^"]*)"[^>]*>\s*</dc-import>'
    )
    match = dc_import_pattern.search(main_body)
    if not match:
        raise RuntimeError("<dc-import name='ClearCoin Card'> not found in main body")
    wrapper_style = match.group(1)
    replacement = f'<div style="{wrapper_style}">\n{card_body}\n</div>'
    main_body = main_body[:match.start()] + replacement + main_body[match.end():]

    # Wire the two "Download The App" CTAs (nav + join section) to the same
    # real APK URL the current production site uses -- the design's source
    # has them pointing at `#join`, which just scrolls to the beta section
    # and doesn't actually offer the APK.
    APK_URL = (
        "https://storage.googleapis.com/clearbridge-dc699.firebasestorage.app/"
        "apk-builds/clearbridge-beta-latest.apk"
    )
    main_body = re.sub(
        r'<a href="#join"([^>]*?)>(\s*(?:<span[^>]*>[^<]*</span>\s*)?Download The App\s*)</a>',
        rf'<a href="{APK_URL}" download="clearbridge-beta.apk"\1>\2</a>',
        main_body,
    )

    responsive_css = extract_responsive_css(current_src).strip()

    # Any Google Fonts <link> already in helmet stays; we just wrap for clarity.
    head_parts = []
    head_parts.append('<meta charset="utf-8">')
    head_parts.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    head_parts.append(
        '<meta name="description" content="ClearBridge -- police clearance reimagined. '
        'The first compliance platform built for the worker, not the employer.">'
    )
    head_parts.append('<title>ClearBridge -- Police Clearance Reimagined</title>')
    if responsive_css:
        # Wrap the mobile overrides in their own <style> tag so the design-system
        # CSS below can override them at wider breakpoints if needed.
        head_parts.append(f'<style>{responsive_css}</style>')
    head_parts.append(main_helmet)
    # Card helmet second, so the card's own animations don't get overridden by
    # any same-named keyframes in the main helmet (in practice they have
    # different names -- verified by hand -- but this ordering is defensive).
    head_parts.append(card_helmet)
    head_html = "\n".join(head_parts)

    OUT.write_text(
        f"<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n{head_html}\n</head>\n<body>\n{main_body}\n</body>\n</html>\n",
        encoding="utf-8",
    )
    print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
