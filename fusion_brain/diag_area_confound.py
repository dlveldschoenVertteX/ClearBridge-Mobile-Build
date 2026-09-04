"""Is the refinement-vs-bare NFIQ2 delta just an AREA effect?

Refinement replaces the bare guide with (detector AND dilated guide). Measured
across the recent population that lands at 0.53-1.08 x the bare guide's own
area -- i.e. refinement usually SHRINKS the mask. NFIQ2 partly rewards valid
ridge area, so a negative delta is consistent with two very different stories:

  (a) refinement removes useful ridge area  -> refinement is harmful
  (b) refinement correctly removes non-pad content NFIQ2 was happy to count
      -> refinement is right and NFIQ2 is the wrong instrument, exactly as
         round 43's crease-trim finding already demonstrated once

Correlating the per-capture NFIQ2 delta against the per-capture AREA ratio
separates them. If the delta is well explained by area alone, this is (b)-
shaped and the result must not be read as "refinement is harmful".
"""
import json, os, statistics

HERE = os.path.dirname(os.path.abspath(__file__))
val = {r['id']: r for r in json.load(open(os.path.join(HERE, 'results', 'mask_refinement_value.json')))}
con = {r['id']: r for r in json.load(open(os.path.join(HERE, 'results', 'mask_contribution.json')))}

xs, ys, rows = [], [], []
for cid, v in val.items():
    c = con.get(cid)
    if not c or c.get('cov_over_guide') is None: continue
    if v.get('prod') is None or v.get('bare') is None: continue
    if not c.get('accepted'):        # bare guide was used in BOTH arms
        continue
    xs.append(c['cov_over_guide']); ys.append(v['prod'] - v['bare'])
    rows.append((cid, c['cov_over_guide'], v['prod'] - v['bare'], v['prod_mask']))

print("captures where refinement actually changed the mask: %d\n" % len(rows))
print("  %-10s %-12s %-8s %s" % ('capture', 'area ratio', 'dNFIQ2', 'mask'))
for cid, a, d, m in sorted(rows, key=lambda r: r[1]):
    print("  %-10s %-12.2f %+-8.0f %s" % (cid, a, d, m))

if len(xs) >= 3:
    mx, my = statistics.mean(xs), statistics.mean(ys)
    sx = statistics.pstdev(xs); sy = statistics.pstdev(ys)
    r = (sum((a-mx)*(b-my) for a, b in zip(xs, ys)) / len(xs)) / (sx*sy) if sx and sy else float('nan')
    print("\n  mean area ratio %.2f   mean dNFIQ2 %+.2f" % (mx, my))
    print("  correlation(area ratio, dNFIQ2) r = %+.3f  (n=%d)" % (r, len(xs)))
    print("  r > 0 means: the more area refinement KEPT, the better it scored")
    print("               -> the delta tracks area, not pad-correctness")
