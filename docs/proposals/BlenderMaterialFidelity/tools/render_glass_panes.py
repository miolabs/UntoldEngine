# Renders the glass test scene with Cycles under an HDR world, and writes the camera in
# engine coordinates for the engine to draw the same view. Read-only on the .blend.
# Run: blender -b glass_panes.blend --python render_glass_panes.py -- <engine scripts dir> <hdr> <out dir>
# The engine's HDR used for the image: Sources/UntoldEngine/Resources/HDR/teatro_massimo_2k.hdr (see below).
import json
import math
import os
import sys

import bpy
from mathutils import Vector

scripts_dir, hdr_path, out_dir = sys.argv[sys.argv.index("--") + 1:][:3]
sys.path.insert(0, scripts_dir)
import untoldexplorer as ux  # noqa: E402

os.makedirs(out_dir, exist_ok=True)
conversion = ux.resolve_conversion_matrix(True, "blender-native")
FOV_Y = 40.0
EYE = Vector((-1.6, -8.2, 1.7))
TARGET = Vector((0.1, 0.6, 0.95))


def to_engine(vector, point=True):
    v = conversion @ Vector((vector[0], vector[1], vector[2], 1.0 if point else 0.0))
    return [round(v[0], 5), round(v[1], 5), round(v[2], 5)]


scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.device = "CPU"
scene.cycles.samples = int(os.environ.get("GLASS_SAMPLES", "256"))
scene.cycles.use_denoising = True
scene.cycles.max_bounces = 16
scene.cycles.transmission_bounces = 16
scene.cycles.glossy_bounces = 8
scene.render.resolution_x, scene.render.resolution_y = 1920, 1080
scene.render.resolution_percentage = 50
scene.render.image_settings.file_format = "PNG"
scene.view_settings.view_transform = "Standard"

world = bpy.data.worlds.new("audit")
world.use_nodes = True
tree = world.node_tree
background = tree.nodes["Background"]
environment = tree.nodes.new("ShaderNodeTexEnvironment")
environment.image = bpy.data.images.load(hdr_path, check_existing=True)
tree.links.new(environment.outputs["Color"], background.inputs["Color"])
# The engine reads the panorama's centre along its forward axis; Blender along -x.
coordinates = tree.nodes.new("ShaderNodeTexCoord")
mapping = tree.nodes.new("ShaderNodeMapping")
mapping.vector_type = "POINT"
mapping.inputs["Rotation"].default_value = (0.0, 0.0, math.radians(90.0))
tree.links.new(coordinates.outputs["Generated"], mapping.inputs["Vector"])
tree.links.new(mapping.outputs["Vector"], environment.inputs["Vector"])
background.inputs["Strength"].default_value = 1.0
scene.world = world

camera_data = bpy.data.cameras.new("cam")
camera_data.sensor_fit = "VERTICAL"
camera_data.angle_y = math.radians(FOV_Y)
camera_data.clip_start = 0.05
camera_data.clip_end = 1000
camera = bpy.data.objects.new("cam", camera_data)
camera.location = EYE
camera.rotation_euler = (TARGET - EYE).to_track_quat("-Z", "Y").to_euler()
scene.collection.objects.link(camera)
scene.camera = camera
scene.render.filepath = os.path.join(out_dir, "glass_blender.png")
bpy.ops.render.render(write_still=True)
json.dump({"eye": to_engine(EYE), "target": to_engine(TARGET), "fov": FOV_Y}, open(os.path.join(out_dir, "view.json"), "w"))
print("GLASSVIEW rendered", scene.render.filepath)