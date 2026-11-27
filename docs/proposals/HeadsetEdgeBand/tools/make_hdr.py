"""Writes the two stand-in room lights used by EdgeProbeScratchTests.testFlipLighting as
uncompressed Radiance .hdr equirects: toplit.hdr (bright above, dark below) and sidelit.hdr
(a bright lobe around one azimuth). python3 -I make_hdr.py <outdir>"""
import sys, math, os
W, H = 256, 128
def rgbe(r, g, b):
    m = max(r, g, b)
    if m < 1e-32: return bytes([0, 0, 0, 0])
    e = math.frexp(m)[1]; scale = 256.0 / (2.0 ** e)
    return bytes([min(255, int(r * scale)), min(255, int(g * scale)), min(255, int(b * scale)), e + 128])
def write(path, lum):
    with open(path, 'wb') as f:
        f.write(b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n"); f.write(f"-Y {H} +X {W}\n".encode())
        for y in range(H):
            elev = (0.5 - (y + 0.5) / H) * 2.0
            row = b""
            for x in range(W):
                az = (x + 0.5) / W * 2.0 * math.pi
                l = lum(elev, az); row += rgbe(l, l, l)
            f.write(row)
out = sys.argv[1]
write(os.path.join(out, "toplit.hdr"), lambda e, a: 1.6 if e > 0.15 else (0.5 if e > -0.05 else 0.03))
write(os.path.join(out, "sidelit.hdr"), lambda e, a: (0.08 + 2.5 * max(0.0, math.cos(a - math.pi * 0.5)) ** 4) if e > -0.1 else 0.02)
print("wrote toplit.hdr and sidelit.hdr in", out)
