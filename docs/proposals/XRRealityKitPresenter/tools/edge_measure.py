"""Measures the silhouettes of the example's slab in a headset screenshot: the lower edge of the
slab (light blue against the room) and the sphere's outline. Prints, for the slab's lower edge, the
boundary's deviation from a fitted straight line (mean and max, in pixels) and the number of steps
(jumps of two pixels or more between neighbouring columns); for the sphere, the deviation of its
outline from a fitted circle."""
import sys, cv2, numpy as np

def slab_mask(img):
    hsv = cv2.cvtColor(img, cv2.COLOR_BGR2HSV)
    # The engine's objects are a pale blue: low saturation, high value, hue around blue.
    h, s, v = cv2.split(hsv)
    mask = ((h > 90) & (h < 135) & (s > 15) & (s < 190) & (v > 90)).astype(np.uint8) * 255
    mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    return mask

def lower_edge(mask, x0, x1):
    ys = []
    xs = []
    for x in range(x0, x1):
        column = np.where(mask[:, x] > 0)[0]
        if len(column) == 0: continue
        ys.append(column.max()); xs.append(x)
    return np.array(xs), np.array(ys)

def right_edge(mask, y0, y1):
    xs = []; ys = []
    for y in range(y0, y1):
        row = np.where(mask[y, :] > 0)[0]
        if len(row) == 0: continue
        xs.append(row.max()); ys.append(y)
    return np.array(xs), np.array(ys)

def measure(path):
    img = cv2.imread(path)
    mask = slab_mask(img)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    # The slab: the widest component.
    best = max(range(1, n), key=lambda i: stats[i, cv2.CC_STAT_WIDTH])
    x, y, w, h, area = stats[best]
    slab = (labels == best).astype(np.uint8) * 255
    # The lower edge over the middle 80 % of the slab's width.
    xs, ys = lower_edge(slab, x + w // 10, x + w - w // 10)
    a, b = np.polyfit(xs, ys, 1)
    residual = ys - (a * xs + b)
    steps = np.abs(np.diff(ys))
    print(f"{path.split('/')[-1]}: slab {w}x{h} px at ({x},{y}); lower edge over {len(xs)} columns: "
          f"deviation from a line mean {np.abs(residual).mean():.2f} px, max {np.abs(residual).max():.2f} px; "
          f"steps >= 2 px: {(steps >= 2).sum()}, largest step {steps.max()} px")
    # The right edge over the middle 80 % of the slab's height (the edge that descends to the right).
    rx, ry = right_edge(slab, y + h // 10, y + h - h // 10)
    if len(rx) > 4:
        a2, b2 = np.polyfit(ry, rx, 1)
        res2 = rx - (a2 * ry + b2)
        steps2 = np.abs(np.diff(rx))
        print(f"    right edge over {len(rx)} rows: deviation from a line mean {np.abs(res2).mean():.2f} px, max {np.abs(res2).max():.2f} px; "
              f"steps >= 2 px: {(steps2 >= 2).sum()}, largest step {steps2.max()} px")
    # The sphere: the roundest small component above the slab.
    # The sphere: small, about as wide as tall, well above the slab, the roundest of those.
    cands = [i for i in range(1, n) if i != best and 400 < stats[i, cv2.CC_STAT_AREA] < 40000
             and 0.7 < stats[i, cv2.CC_STAT_WIDTH] / max(1, stats[i, cv2.CC_STAT_HEIGHT]) < 1.4
             and stats[i, cv2.CC_STAT_TOP] + stats[i, cv2.CC_STAT_HEIGHT] < y - 60]
    def circularity(i):
        comp = (labels == i).astype(np.uint8)
        contours, _ = cv2.findContours(comp, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        c = max(contours, key=cv2.contourArea)
        per = cv2.arcLength(c, True)
        return 4 * np.pi * cv2.contourArea(c) / (per * per) if per > 0 else 0
    if cands:
        i = max(cands, key=circularity)
        # The blue mask loses the sphere's bright, desaturated top: within a window about the
        # candidate, take bright low-saturation pixels too, then the largest component.
        sx, sy, sw, sh = stats[i, cv2.CC_STAT_LEFT], stats[i, cv2.CC_STAT_TOP], stats[i, cv2.CC_STAT_WIDTH], stats[i, cv2.CC_STAT_HEIGHT]
        pad = int(max(sw, sh) * 0.4)
        wx0, wy0 = max(0, sx - pad), max(0, sy - pad)
        wx1, wy1 = min(img.shape[1], sx + sw + pad), min(img.shape[0], sy + sh + pad)
        hsv = cv2.cvtColor(img[wy0:wy1, wx0:wx1], cv2.COLOR_BGR2HSV)
        h_, s_, v_ = cv2.split(hsv)
        window = (((h_ > 90) & (h_ < 135) & (v_ > 90)) | ((s_ < 30) & (v_ > 150))).astype(np.uint8)
        window = cv2.morphologyEx(window, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
        nw, lw, sw_, _ = cv2.connectedComponentsWithStats(window)
        # The component that contains the blue candidate's centre.
        ccx, ccy = sx + sw // 2 - wx0, sy + sh // 2 - wy0
        k = lw[min(ccy, lw.shape[0] - 1), min(ccx, lw.shape[1] - 1)]
        if k == 0:
            k = max(range(1, nw), key=lambda j: sw_[j, cv2.CC_STAT_AREA])
        sphere = np.zeros(mask.shape, np.uint8)
        sphere[wy0:wy1, wx0:wx1] = (lw == k).astype(np.uint8)
        contours, _ = cv2.findContours(sphere, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
        c = max(contours, key=cv2.contourArea)
        cv2.imwrite(path.rsplit('.', 1)[0] + "-sphere.png", sphere * 255)
        (cx, cy), r = cv2.minEnclosingCircle(c)
        pts = c.reshape(-1, 2).astype(np.float64)
        d = np.sqrt(((pts - [cx, cy]) ** 2).sum(1))
        # A circle fitted by least squares on the contour radius.
        print(f"    sphere: radius {d.mean():.1f} px, outline deviation from a circle mean {np.abs(d - d.mean()).mean():.2f} px, max {np.abs(d - d.mean()).max():.2f} px")
    cv2.imwrite(path.rsplit('.', 1)[0] + "-mask.png", slab)

for p in sys.argv[1:]:
    measure(p)
