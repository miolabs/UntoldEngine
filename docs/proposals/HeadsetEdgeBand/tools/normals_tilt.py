import bpy, math
from mathutils import Vector
names = ["SM_Env_Railing_Stone_Pillar_10", "SM_Env_Railing_Stone_10", "SM_Env_Pillar_Stone_10", "SM_Env_Wall_Half_2", "SM_Env_Stairs_Spiral_2"]
for name in names:
    o = bpy.data.objects.get(name)
    if o is None or o.type != 'MESH':
        print("MISSING", name); continue
    m = o.data
    maxang = 0.0; count = 0; over20 = 0
    hist = [0]*10
    for p in m.polygons:
        fn = p.normal
        for li in p.loop_indices:
            cn = m.loops[li].normal
            d = max(-1.0, min(1.0, fn.dot(cn)))
            ang = math.degrees(math.acos(d))
            maxang = max(maxang, ang); count += 1
            if ang > 20: over20 += 1
            hist[min(9, int(ang // 10))] += 1
    print(f"{name}: polys={len(m.polygons)} corners={count} max corner-vs-face angle={maxang:.1f} deg, corners over 20 deg={over20}, histogram by 10 deg={hist}")
