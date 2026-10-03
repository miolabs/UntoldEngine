# Performance baselines

One folder per device model (as `hw.model` on macOS or `hw.machine` elsewhere, e.g. `Mac16,6`,
`RealityDevice17,1`, `iPhone18,1`), one folder per platform inside it, one JSON per benchmark scene.
Each file is the scene result exactly as `Examples/PerfBench` wrote it plus the render
configuration it was measured with, so `scripts/perf/compare_baseline.py` refuses to compare runs
that differ in platform, texture layout, foveation, viewport or view count.

Write a baseline with `scripts/perf/run_bench.sh <platform> --update-baseline` from a known-good
commit, in release, on a cool device, and record the commit in the `label` field.
