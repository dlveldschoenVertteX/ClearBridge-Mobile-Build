"""
pyfing enhancement sidecar HTTP service.

Wraps the `pyfing` Python package (github.com/raffaele-cappelli/pyfing,
`pip install pyfing`) behind an HTTP endpoint so processEnhanceAndScore
(Firebase Functions, buildpack-based deploy, no Dockerfile of its own) can
call it without the shared function taking on a second full ML framework
(TensorFlow/Keras, needed for pyfing's SNFEN/SNFOE/SNFFE/LEADER models)
alongside its existing PyTorch stack. Same split-service reasoning as
nfiq2_service/ and the NBIS mindtct/bozorth3 addition to it.

Verified before adding this dependency (2026-07-15): MIT license (commercial
use/redistribution explicitly fine), maintainer Raffaele Cappelli is an
associate professor at the University of Bologna and FVC (Fingerprint
Verification Competition) co-organizer -- a real, identifiable authority in
this field, not an anonymous source. Pretrained weights ship INSIDE the
MIT-licensed PyPI package itself (confirmed via source read: model classes
build weight paths from os.path.dirname(__file__), no external
get_file/requests/urlretrieve calls anywhere) -- no separate third-party
download host to vet, unlike NBIS's situation. See
docs/GROUND_TRUTH_MATCHING_SCOPE.md and CLAUDE.md's "Pretrained
fingerphoto-enhancement models" section for the fuller evaluation trail
(FpEnhancer and FingerFlow were both considered and ruled out first).

First real test (this session, in-sandbox on a real ClearBridge burst
frame): pyfing's SNFEN enhancement, run on a raw single frame with a crude
manual crop (no real guideRegion alignment, no multi-frame fusion --
everything this project's own classical pipeline already does that this
quick test skipped), scored competitively with the current production
pipeline's own tuned output on the same capture (bozorth3 match score 7 vs.
6 against the CTO's ink scan) via mindtct_client.match_prints(). Real
promise, not yet a confirmed win -- needs testing with the pipeline's own
guideRegion-cropped input once wired in as a max-of-variants candidate.
"""

import io
import logging
import os

import numpy as np
from flask import Flask, request, jsonify, Response
from PIL import Image

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

_ENHANCE_TIMEOUT_SEC = 25  # pyfing's Keras models are slower than mindtct/bozorth3's C binaries


@app.route('/healthz', methods=['GET'])
def healthz():
    return jsonify({'ok': True}), 200


def _decode_gray(image_bytes: bytes) -> 'np.ndarray':
    img = Image.open(io.BytesIO(image_bytes)).convert('L')
    return np.array(img)


@app.route('/enhance', methods=['POST'])
def enhance():
    """Enhance a fingerprint image via pyfing. Request body = raw image
    bytes (same convention as the NFIQ2 sidecar's /score). Optional query
    params: method ('SNFEN' default, neural; or 'GBFEN', classical Gabor --
    SNFEN scored higher in this project's own first real test), dpi (int,
    default 500). Returns the enhanced image directly as PNG bytes on
    success (Content-Type: image/png), or a JSON error dict on failure."""
    image_bytes = request.get_data()
    if not image_bytes:
        return jsonify({'error': 'empty request body'}), 400

    method = request.args.get('method', 'SNFEN')
    dpi = int(request.args.get('dpi', 500))

    try:
        import pyfing

        gray = _decode_gray(image_bytes)
        mask = pyfing.fingerprint_segmentation(gray, dpi=dpi)
        orientation = pyfing.orientation_field_estimation(gray, mask, dpi=dpi)
        frequency = pyfing.frequency_estimation(gray, orientation, mask, dpi=dpi)
        enhanced = pyfing.fingerprint_enhancement(gray, orientation, frequency, mask, dpi=dpi, method=method)

        buf = io.BytesIO()
        Image.fromarray(enhanced).save(buf, format='PNG')
        return Response(buf.getvalue(), mimetype='image/png')

    except Exception as e:   # noqa: BLE001 — this endpoint must always return, never crash
        logger.exception('pyfing enhancement failed')
        return jsonify({'error': str(e)}), 500


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 8080)))
