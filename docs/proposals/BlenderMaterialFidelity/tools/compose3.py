# Puts the renders of view_cooked3.py side by side: one row per object, a column each
# for Blender, the cook before and the cook after, with a line of labels on top.
# Usage: python compose3.py <views dir> <out.jpg> <safe name> [<safe name> ...]
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

views, out_path, names = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3:]
columns = [("blender", "Blender (Cycles)"), ("before", "Cook before"), ("after", "Cook with the bake")]
cell_w, cell_h, gap, header = 720, 480, 8, 44

sheet = Image.new("RGB", (len(columns) * cell_w + (len(columns) - 1) * gap, header + len(names) * cell_h + (len(names) - 1) * gap), "white")
draw = ImageDraw.Draw(sheet)
font = None
for candidate in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf", "/Library/Fonts/Arial.ttf"):
    try:
        font = ImageFont.truetype(candidate, 26)
        break
    except OSError:
        continue
font = font or ImageFont.load_default()

for column, (_, label) in enumerate(columns):
    x = column * (cell_w + gap)
    width = draw.textlength(label, font=font)
    draw.text((x + (cell_w - width) / 2, 8), label, fill=(30, 30, 30), font=font)

for row, name in enumerate(names):
    for column, (suffix, _) in enumerate(columns):
        image = Image.open(views / f"{name}_{suffix}.png").convert("RGB").resize((cell_w, cell_h), Image.LANCZOS)
        sheet.paste(image, (column * (cell_w + gap), header + row * (cell_h + gap)))

sheet.save(out_path, quality=88, optimize=True)
print("COMPOSED", out_path, sheet.size, out_path.stat().st_size // 1024, "KB")
