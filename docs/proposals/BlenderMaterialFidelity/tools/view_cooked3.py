# Visual check: render Blender's own object and its cooked .untold side by side (Cycles),
# from the same camera and light. Read-only on the .blend (never saved).
# Run: Blender -b <file.blend> --python view_cooked3.py -- <scripts dir> <label=pack.untoldpack>[,<label=pack>...] <out dir> <object name> [...]
# The packs are cooked with --ConvertOrientation (blender-native): their models are put back in Blender's axes.
import json
import math
import os
import struct
import sys

import bpy
import numpy as np
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
scripts_dir, pack_specs, out_dir, names = argv[0], argv[1], argv[2], argv[3:]
sys.path.insert(0, scripts_dir)
import untoldexplorer as u  # noqa: E402

os.makedirs(out_dir, exist_ok=True)
packs = []
for pack_spec in pack_specs.split(","):
    label, _, pack_path = pack_spec.partition("=")
    manifest = json.load(open(pack_path))
    packs.append((label, os.path.dirname(pack_path), {entry["displayName"]: entry for entry in manifest["models"]}))
TO_BLENDER_AXES = u.make_export_orientation_matrix("blender-native", 1.0).inverted()


def read_untold(path):
    raw = open(path, "rb").read()
    header_size, chunk_count = struct.unpack_from("<II", raw, 20)
    chunks = {}
    for index in range(chunk_count):
        kind, compression, offset, size, _, count, _ = struct.unpack_from("<IIQQQII", raw, header_size + index * 40)
        assert compression == 0
        chunks[kind] = (offset, size, count)

    def chunk(name):
        offset, size, count = chunks.get(u.CHUNK_TYPES[name], (0, 0, 0))
        return raw[offset:offset + size], count

    strings, _ = chunk("string_table")

    def text(offset):
        return strings[offset:strings.index(b"\0", offset)].decode()

    data, count = chunk("texture_table")
    stride = len(data) // count if count else 0
    textures = [text(struct.unpack_from("<I", data, i * stride + 4)[0]) for i in range(count)]
    data, count = chunk("material_table")
    materials = []
    for i in range(count):
        o = i * 108
        base = struct.unpack_from("<4f", data, o + 8)
        normal_scale, metallic, roughness = struct.unpack_from("<3f", data, o + 36)
        idx = struct.unpack_from("<6I", data, o + 56)
        channels = struct.unpack_from("<I", data, o + 100)[0]
        materials.append({
            "name": text(struct.unpack_from("<I", data, o)[0]), "base": base, "metallic": metallic, "roughness": roughness,
            "textures": [textures[k] if k < len(textures) else None for k in idx],
            "rough_channel": channels & 3, "metal_channel": (channels >> 2) & 3,
        })
    data, count = chunk("entity_table")
    entities = []
    for i in range(count):
        o = i * 136
        entity_id, parent, name_offset, first_mesh, mesh_count, _ = struct.unpack_from("<6I", data, o)
        columns = struct.unpack_from("<16f", data, o + 72)
        local = Matrix([[columns[c * 4 + r] for c in range(4)] for r in range(4)])
        entities.append({"id": entity_id, "parent": parent, "name": text(name_offset), "first_mesh": first_mesh, "mesh_count": mesh_count, "local": local})
    data, count = chunk("mesh_table")
    vertex_data, _ = chunk("vertex_data")
    index_data, _ = chunk("index_data")
    meshes = []
    for i in range(count):
        o = i * 104
        entity_id, _, material_index, index_type, vertex_count, index_count, stride, _ = struct.unpack_from("<8I", data, o)
        vertex_offset, index_offset, vertex_size, index_size = struct.unpack_from("<4Q", data, o + 32)
        vertices = np.frombuffer(vertex_data[vertex_offset:vertex_offset + vertex_size], dtype=u._VERTEX_DTYPE)
        indices = np.frombuffer(
            index_data[index_offset:index_offset + index_size], dtype=np.uint16 if index_type == u.INDEX_TYPE_UINT16 else np.uint32
        )
        meshes.append({"material": material_index, "vertices": vertices, "indices": indices.astype(np.int64)})
    return entities, meshes, materials


def cooked_material(record, model_dir, cache):
    key = (model_dir, record["name"])
    if key in cache:
        return cache[key]
    material = bpy.data.materials.new("cooked_" + record["name"])
    material.use_nodes = True
    tree = material.node_tree
    principled = next(n for n in tree.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled")
    principled.inputs["Base Color"].default_value = record["base"]
    principled.inputs["Metallic"].default_value = record["metallic"]
    principled.inputs["Roughness"].default_value = record["roughness"]

    def image_node(uri, colorspace):
        node = tree.nodes.new("ShaderNodeTexImage")
        node.image = bpy.data.images.load(os.path.normpath(os.path.join(model_dir, uri)), check_existing=True)
        node.image.colorspace_settings.name = colorspace
        return node

    base, normal, metal, rough = record["textures"][:4]
    if base:
        tree.links.new(image_node(base, "sRGB").outputs["Color"], principled.inputs["Base Color"])
    for uri, channel, socket in ((rough, record["rough_channel"], "Roughness"), (metal, record["metal_channel"], "Metallic")):
        if uri:
            separate = tree.nodes.new("ShaderNodeSeparateColor")
            tree.links.new(image_node(uri, "Non-Color").outputs["Color"], separate.inputs["Color"])
            tree.links.new(separate.outputs[channel], principled.inputs[socket])
    if normal:
        normal_map = tree.nodes.new("ShaderNodeNormalMap")
        tree.links.new(image_node(normal, "Non-Color").outputs["Color"], normal_map.inputs["Color"])
        tree.links.new(normal_map.outputs["Normal"], principled.inputs["Normal"])
    cache[key] = material
    return material


def build_cooked(scene, pack_dir, entry, wanted_prefix):
    path = os.path.join(pack_dir, entry["path"])
    model_dir = os.path.dirname(path)
    entities, meshes, materials = read_untold(path)
    by_id = {entity["id"]: entity for entity in entities}
    root = Matrix(entry["transform"])
    cache = {}
    built = 0
    for entity in entities:
        if not entity["name"].startswith(wanted_prefix) or entity["mesh_count"] == 0:
            continue
        world = entity["local"]
        parent = by_id.get(entity["parent"])
        while parent is not None:
            world = parent["local"] @ world
            parent = by_id.get(parent["parent"])
        world = root @ world
        for mesh_record in meshes[entity["first_mesh"]:entity["first_mesh"] + entity["mesh_count"]]:
            vertices = mesh_record["vertices"]
            positions = np.stack([vertices["px"], vertices["py"], vertices["pz"]], axis=1)
            triangles = mesh_record["indices"].reshape(-1, 3)
            mesh = bpy.data.meshes.new("cooked")
            mesh.from_pydata(positions.tolist(), [], triangles.tolist())
            uv = np.stack([vertices["uv0u"], vertices["uv0v"]], axis=1).copy().view(np.float16).astype(np.float32)
            layer = mesh.uv_layers.new(name="UVMap")
            layer.data.foreach_set("uv", uv[triangles.reshape(-1)].ravel())
            mesh.materials.append(cooked_material(materials[mesh_record["material"]], model_dir, cache))
            mesh.update()
            obj = bpy.data.objects.new("cooked_" + entity["name"], mesh)
            obj.matrix_world = TO_BLENDER_AXES @ world
            scene.collection.objects.link(obj)
            built += 1
    return built


def setup_scene(name):
    scene = bpy.data.scenes.new(name)
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.cycles.samples = 24
    scene.cycles.use_denoising = False
    scene.render.resolution_x, scene.render.resolution_y = 900, 600
    scene.render.image_settings.file_format = "PNG"
    scene.view_settings.view_transform = "Standard"
    world = bpy.data.worlds.new(name)
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs["Color"].default_value = (0.55, 0.6, 0.7, 1.0)
    world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.6
    scene.world = world
    return scene


def add_camera_and_sun(scene, centre, size, normal, distance_factor):
    normal = Vector(normal).normalized()
    side = normal.cross(Vector((0, 0, 1)))
    if side.length < 1.0e-3:
        side = Vector((1, 0, 0))
    side.normalize()
    up = side.cross(normal).normalized()
    direction = (normal + 0.45 * side + 0.3 * up).normalized()
    location = Vector(centre) + direction * size * distance_factor
    camera_data = bpy.data.cameras.new("cam")
    camera_data.lens = 50
    camera_data.clip_start = 0.01
    camera_data.clip_end = 10000
    camera = bpy.data.objects.new("cam", camera_data)
    camera.location = location
    camera.rotation_euler = (Vector(centre) - location).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(camera)
    scene.camera = camera
    sun_data = bpy.data.lights.new("sun", "SUN")
    sun_data.energy = 3.0
    sun = bpy.data.objects.new("sun", sun_data)
    sun.rotation_euler = ((normal + 0.8 * side + 0.9 * up).normalized() * -1).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(sun)


for spec in names:
    spec, _, focus_material = spec.partition("#")
    name, _, factor = spec.partition("@")
    distance_factor = float(factor) if factor else 1.6
    obj = bpy.data.objects.get(name)
    if obj is None:
        print("VIEW missing object", name)
        continue
    root = obj
    while root.parent is not None:
        root = root.parent
    if any(root.name not in models for _, _, models in packs):
        print("VIEW no pack model for", name, "root", root.name)
        continue
    corners = [obj.matrix_world @ Vector(corner) for corner in obj.bound_box]
    low = Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
    high = Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
    centre = (low + high) / 2
    size = max((high - low).length, 0.05)
    # the facing most of its surface has, in the world
    mesh = obj.data
    count = len(mesh.polygons)
    normals = np.empty(count * 3, np.float32)
    areas = np.empty(count, np.float32)
    mesh.polygons.foreach_get("normal", normals)
    mesh.polygons.foreach_get("area", areas)
    matrix = np.array([[obj.matrix_world[r][c] for c in range(3)] for r in range(3)])
    placed = u.facing_areas_placed(u.facing_areas(normals, areas), matrix, True)
    plane = u.choose_bake_plane(placed)
    normal = [0.0, 0.0, 0.0]
    normal["xyz".index(plane[1])] = 1.0 if plane[0] == "+" else -1.0
    if focus_material:
        # look at the largest face of that material, from `factor` metres
        slot = next(i for i, s in enumerate(obj.material_slots) if s.material and s.material.name == focus_material)
        indices = np.empty(count, np.int32)
        mesh.polygons.foreach_get("material_index", indices)
        candidates = np.flatnonzero(indices == slot)
        face = mesh.polygons[int(candidates[areas[candidates].argmax()])]
        centre = obj.matrix_world @ face.center
        world_normal = (obj.matrix_world.to_3x3().inverted().transposed() @ face.normal).normalized()
        normal = list(world_normal)
        size = 1.0
        plane = "face of " + focus_material
    safe = "".join(c if c.isascii() and c.isalnum() else "_" for c in (name + "_" + focus_material))[:60]

    original = setup_scene("original")
    original.collection.objects.link(obj)
    add_camera_and_sun(original, centre, size, normal, distance_factor)
    original.render.filepath = os.path.join(out_dir, f"{safe}_blender.png")
    bpy.ops.render.render(write_still=True, scene=original.name)

    built = []
    for label, pack_dir, models in packs:
        cooked = setup_scene("cooked_" + label)
        built.append(build_cooked(cooked, pack_dir, models[root.name], name))
        add_camera_and_sun(cooked, centre, size, normal, distance_factor)
        cooked.render.filepath = os.path.join(out_dir, f"{safe}_{label}.png")
        bpy.ops.render.render(write_still=True, scene=cooked.name)
    print("VIEW", name, "| root", root.name, "| facing", plane, "| size", round(size, 2), "| cooked meshes", built,
          "| materials", [slot.material.name for slot in obj.material_slots if slot.material])
