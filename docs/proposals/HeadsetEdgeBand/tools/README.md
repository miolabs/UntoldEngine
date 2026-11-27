# Headset edge band — probe tooling (2026-10-16)

Reproduces on a Mac what Harold recorded on the Vision Pro with engine PR #1359: dark bands
along the edges of the Simple Dungeons models. Everything here ran from the Claude scratchpad,
so the paths inside `EdgeProbeScratchTests.swift` (`Self.scratch`) must be pointed at a folder
holding `dungeon/dungeon.untoldpack` (the exported pack), `hdr/*.hdr` and an output folder.

- `EdgeProbeScratchTests.swift` — a scratch render test (drop into `Tests/UntoldEngineRenderTests`
  of the PR checkout, never commit). Loads the pack by absolute path, then: `testMatrixNoTAA`,
  `testMatrixTAA` (the settings matrix), `testFoveatedMotion` (rate map + moving camera),
  `testSSAOHaloSynthetic` (a wall behind a pillar), `testFlipLighting` (the back-face flip under a
  room-like image light; `PROBE_TAG` names the capture, `PROBE_HDR` picks the HDR).
  Run: `CI=true PROBE_TAG=flipOn PROBE_HDR=sidelit.hdr xcrun swift test --disable-swift-testing
  --skip-build --filter UntoldEngineRenderTests.EdgeProbeScratchTests/testFlipLighting`
- The flip A/B: change `< 0.0` to `< -2.0` in the back-face test of `modelShader.metal`, rebuild the
  macOS metallib only (`xcrun -sdk macosx metal -mmacosx-version-min=14.0 UntoldEngineKernels.metal -c
  -o x.air && xcrun -sdk macosx metallib x.air -o UntoldEngineKernels.metallib` in
  `Sources/UntoldEngine/UntoldEngineKernels`), `swift build --build-tests`, run with another tag,
  then `git checkout` the shader and the metallib.
- Export of the .blend: `Blender --background --disable-autoexec --python-exit-code 1 --python
  scripts/untoldexplorer.py -- --input dungeon.blend --output <out>/dungeon.untoldpack --assets-dir
  <out> --convert-orientation`.
- `frames.swift` / `fine.swift` — frame extraction from the recording with AVFoundation (the
  Homebrew ffmpeg on this Mac is broken). `pixels.swift` / `col.swift` — luminance profiles along a
  row / column. `ratio.swift` — on/off ratio image (shows an AO multiply). `mask.swift` — pixels that
  differ between two renders (the flip's footprint). `compose.swift` — side-by-side crops.
- `inspect_blend.py` / `normals_tilt.py` — Blender headless: the scene's contents, and how far the
  corner normals tilt from their faces (45–72° in this kit).
- `make_hdr.py` — the stand-in room lights.
Build each Swift tool with `xcrun swiftc -O -o <name> <name>.swift`.
- `signed.swift` — red where the first render is darker than the second, green where brighter;
  `rimstat.swift` — how many pixels got darker and by how much. Used to compare the fixed shader
  with the flip compiled out and with the old flip on the dungeon pack (2026-10-17).
