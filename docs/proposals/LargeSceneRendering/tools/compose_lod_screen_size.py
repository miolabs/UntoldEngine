from PIL import Image, ImageDraw, ImageFont
import os
src = '/private/tmp/claude-501/-Users-godshadow-Projects-Untold/7fa62dfe-a82f-410f-8264-10148a508842/scratchpad/sheet/UntoldEngineRenderingTest'
out = '/private/tmp/claude-501/-Users-godshadow-Projects-Untold/7fa62dfe-a82f-410f-8264-10148a508842/scratchpad/sheet/lod_screen_size.jpg'
# The same window of the frame in every panel, centred on the model.
cx, cy, cw, ch = 962, 600, 650, 620
rows = [("Field of view 60°", "wide"), ("Field of view 20°, the camera zoomed in", "zoom")]
cols = [("Full model", "reference"), ("Before: the level by the distance", "before"), ("After: the level by the size on screen", "after")]
levels = {("wide","reference"): "level 0, 2,264 triangles", ("wide","before"): "level 3, 118 triangles", ("wide","after"): "level 3, 118 triangles",
          ("zoom","reference"): "level 0, 2,264 triangles", ("zoom","before"): "level 3, 118 triangles", ("zoom","after"): "level 0, 2,264 triangles"}
pw, ph = 460, 438
margin, gap, header, rowlabel, caption = 16, 10, 34, 30, 26
W = margin * 2 + 3 * pw + 2 * gap
H = margin + header + 2 * (rowlabel + ph + caption + gap) + margin
sheet = Image.new('RGB', (W, H), (245, 245, 245))
draw = ImageDraw.Draw(sheet)
def font(size, bold=False):
    for name in (['/System/Library/Fonts/HelveticaNeue.ttc'] if not bold else ['/System/Library/Fonts/HelveticaNeue.ttc']):
        try: return ImageFont.truetype(name, size, index=1 if bold else 0)
        except Exception: pass
    return ImageFont.load_default()
title_font, label_font, small_font = font(20, True), font(18, True), font(16)
for c, (ctitle, _) in enumerate(cols):
    x = margin + c * (pw + gap)
    draw.text((x + pw / 2, margin + header / 2), ctitle, fill=(30, 30, 30), font=title_font, anchor='mm')
y = margin + header
for r, (rtitle, rkey) in enumerate(rows):
    draw.text((margin, y + rowlabel / 2), rtitle, fill=(30, 30, 30), font=label_font, anchor='lm')
    y += rowlabel
    for c, (_, ckey) in enumerate(cols):
        x = margin + c * (pw + gap)
        im = Image.open(os.path.join(src, f'{rkey}_{ckey}.png')).convert('RGB')
        im = im.crop((cx - cw // 2, cy - ch // 2, cx + cw // 2, cy + ch // 2)).resize((pw, ph), Image.LANCZOS)
        sheet.paste(im, (x, y))
        draw.rectangle((x, y, x + pw - 1, y + ph - 1), outline=(200, 200, 200))
        draw.text((x + pw / 2, y + ph + caption / 2), levels[(rkey, ckey)], fill=(60, 60, 60), font=small_font, anchor='mm')
    y += ph + caption + gap
sheet.save(out, quality=82, optimize=True)
print(out, sheet.size, os.path.getsize(out) // 1024, 'KB')
