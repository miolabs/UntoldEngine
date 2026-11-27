import bpy, sys
print("BLENDER", bpy.app.version_string)
print("file", bpy.data.filepath)
print("scenes", [s.name for s in bpy.data.scenes])
sc = bpy.context.scene
print("unit scale", sc.unit_settings.scale_length, "fps", sc.render.fps)
print("objects", len(bpy.data.objects), "meshes", len(bpy.data.meshes), "materials", len(bpy.data.materials), "images", len(bpy.data.images), "lights", len([o for o in bpy.data.objects if o.type=='LIGHT']))
for o in bpy.data.objects:
    extra = ""
    if o.type == 'MESH':
        m = o.data
        flat = sum(1 for p in m.polygons if not p.use_smooth)
        smooth = len(m.polygons) - flat
        cn = m.has_custom_normals if hasattr(m, "has_custom_normals") else None
        autosmooth = getattr(m, "use_auto_smooth", None)
        mods = [(md.type, md.name) for md in o.modifiers]
        mats = [ms.material.name if ms.material else None for ms in o.material_slots]
        links = [ms.link for ms in o.material_slots]
        extra = f"verts={len(m.vertices)} polys={len(m.polygons)} flat={flat} smooth={smooth} customNormals={cn} autosmooth={autosmooth} mods={mods} mats={mats} links={links} scale={tuple(round(s,3) for s in o.scale)}"
    elif o.type == 'LIGHT':
        l = o.data
        extra = f"light type={l.type} energy={l.energy} color={tuple(l.color)} shadow={getattr(l,'use_shadow',None)}"
    print(f"OBJ {o.name!r} type={o.type} parent={o.parent.name if o.parent else None} data={o.data.name if o.data else None} {extra}")
print("--- materials")
for mt in bpy.data.materials:
    if not mt.use_nodes:
        print(f"MAT {mt.name!r} nodes=False diffuse={tuple(mt.diffuse_color)} blend={mt.blend_method}")
        continue
    nodes = [(n.type, n.name) for n in mt.node_tree.nodes]
    bsdf = next((n for n in mt.node_tree.nodes if n.type=='BSDF_PRINCIPLED'), None)
    info = ""
    if bsdf:
        def val(name):
            i = bsdf.inputs.get(name)
            if i is None: return None
            if i.is_linked: return f"<linked:{i.links[0].from_node.type}>"
            v = i.default_value
            try: return tuple(round(x,3) for x in v)
            except TypeError: return round(v,3) if isinstance(v,float) else v
        info = " ".join(f"{k}={val(k)}" for k in ["Base Color","Metallic","Roughness","Alpha","Emission Color","Emission Strength","Transmission Weight","Coat Weight","Normal"])
    print(f"MAT {mt.name!r} blend={mt.blend_method} backface_culling={mt.use_backface_culling} nodes={nodes} {info}")
print("--- images")
for im in bpy.data.images:
    print(f"IMG {im.name!r} size={tuple(im.size)} packed={im.packed_file is not None} path={im.filepath!r} colorspace={im.colorspace_settings.name}")
print("--- world")
w = sc.world
if w and w.use_nodes:
    print("world nodes", [(n.type, n.name) for n in w.node_tree.nodes])
    bg = next((n for n in w.node_tree.nodes if n.type=='BACKGROUND'), None)
    if bg: print("world bg color", tuple(bg.inputs[0].default_value), "strength", bg.inputs[1].default_value)
print("--- custom props on scene:", dict(sc.items()) if hasattr(sc, 'items') else None)
