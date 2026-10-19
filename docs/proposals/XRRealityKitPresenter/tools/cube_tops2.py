"""The cubes as their own pale-blue components above the slab: for each, the topmost pixel per
column over the middle 70 % of its width (the far edge of the top face against the room), a line
fit, the residual rms and peak-to-peak, the steps, the dominant wobble period; and a crop of the
middle cube's top edge, upscaled 4x, saved beside the capture for a look."""
import sys, cv2, numpy as np
from edge_measure import slab_mask

def run(path):
    img = cv2.imread(path)
    mask = slab_mask(img)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    slab = max(range(1, n), key=lambda i: stats[i, cv2.CC_STAT_WIDTH])
    sx, sy, sw, sh, _ = stats[slab]
    cubes = [i for i in range(1, n) if i != slab and stats[i, cv2.CC_STAT_AREA] > 4000
             and 80 < stats[i, cv2.CC_STAT_WIDTH] < 400 and stats[i, cv2.CC_STAT_TOP] < sy + sh
             and 0.6 < stats[i, cv2.CC_STAT_WIDTH] / stats[i, cv2.CC_STAT_HEIGHT] < 1.8]
    cubes.sort(key=lambda i: stats[i, cv2.CC_STAT_LEFT])
    print(f"{path.split('/')[-1]}: slab {sw}x{sh} at ({sx},{sy}); {len(cubes)} cube component(s): " +
          ", ".join(f"{stats[i, cv2.CC_STAT_WIDTH]}x{stats[i, cv2.CC_STAT_HEIGHT]} at ({stats[i, cv2.CC_STAT_LEFT]},{stats[i, cv2.CC_STAT_TOP]})" for i in cubes))
    for k, i in enumerate(cubes):
        x, y, w, h, _ = stats[i]
        comp = labels == i
        m = int(w * 0.15)
        xs, ys = [], []
        for cx in range(x + m, x + w - m):
            col = np.where(comp[:, cx])[0]
            if len(col): xs.append(cx); ys.append(col.min())
        xs = np.array(xs); ys = np.array(ys, dtype=float)
        if len(xs) < 20: continue
        p = np.polyfit(xs, ys, 1); r = ys - np.polyval(p, xs)
        steps = np.abs(np.diff(ys))
        f = np.fft.rfft(r - r.mean()); freqs = np.fft.rfftfreq(len(r), 1.0); power = np.abs(f) ** 2
        sel = (freqs > 1 / 120) & (freqs < 1 / 6)
        period = 1 / freqs[sel][np.argmax(power[sel])] if sel.any() else float('nan')
        print(f"    cube {k + 1}: top edge over {len(xs)} columns, slope {p[0]:+.3f}; residual rms {r.std():.2f} px, p-p {r.max() - r.min():.2f} px; "
              f"steps >= 2 px: {(steps >= 2).sum()}, largest {int(steps.max())} px; dominant wobble period {period:.0f} px")
        if k == 1:
            # The middle cube's top edge: a strip 24 px tall around the edge, the middle 70 % of the width, upscaled 4x.
            y0 = int(np.polyval(p, xs).min()) - 10; y1 = y0 + 24
            crop = img[max(0, y0):y1, x + m:x + w - m]
            crop = cv2.resize(crop, None, fx=4, fy=4, interpolation=cv2.INTER_NEAREST)
            out = path.replace('.png', '-cubetop.png'); cv2.imwrite(out, crop); print(f"    crop: {out} ({crop.shape[1]}x{crop.shape[0]})")

for p in sys.argv[1:]:
    run(p)
