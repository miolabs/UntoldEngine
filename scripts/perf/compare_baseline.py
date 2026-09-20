#!/usr/bin/env python3
"""Compare PerfBench run summaries against the stored baseline for the same device model.

Baselines live in perf/baselines/<model>/<platform>/<scene>.json and hold the scene result as the
app wrote it, so a baseline is only ever compared with the same platform, layout, foveation and
viewport. Exit status 1 means at least one metric regressed past its threshold.

Several summaries may be given (repeated runs): time metrics are aggregated by their minimum
across runs, rates by their mean. On a lightly loaded machine CPU and GPU clocks drift between
runs and only ever inflate a time, so the minimum over a few runs is the stable number.

    compare_baseline.py perf/results/<run>/summary.json [more summary.json ...]
                        [--baselines DIR] [--update]
                        [--time-tolerance 0.10] [--rate-tolerance 0.005] [--pass-tolerance 0.20]
"""
import argparse
import json
import os
import sys

FRAME_METRICS = [
    ("p95FrameMs", "p95 frame ms"),
    ("p99FrameMs", "p99 frame ms"),
    ("meanFrameMs", "mean frame ms"),
    ("minGPUExecutionMs", "min GPU ms"),
]
# Reported, never judged: it follows the GPU clock state more than the workload.
INFO_METRICS = [("meanGPUExecutionMs", "mean GPU ms")]
# Per-system CPU means worth a line each; the rest are compared silently.
TIMING_FIELDS = [
    "updateMs", "encodeMs", "cullingMs", "scenegraphMs", "animationMs", "physicsMs",
    "scriptingMs", "gameUpdateMs", "semaphoreWaitMs", "compositorUpdateMs", "compositorSubmissionMs",
]


def load(path):
    with open(path) as f:
        return json.load(f)


def safe_model(name):
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in name)


def rate(numerator, denominator):
    return (numerator / denominator) if denominator else 0.0


def config_key(render):
    return (render["platform"], render.get("layout"), render.get("foveation"), render.get("viewportWidth"),
            render.get("viewportHeight"), render.get("viewCount"), render.get("antiAliasing", "fxaa"))


def aggregate(scenes):
    """Fold the same scene from several runs into one record: min of times, mean of rates."""
    first = json.loads(json.dumps(scenes[0]))
    s = first["summary"]
    for key, _ in FRAME_METRICS + INFO_METRICS:
        s[key] = min(x["summary"].get(key, 0.0) for x in scenes)
    s["worstFrameMs"] = min(x["summary"].get("worstFrameMs", 0.0) for x in scenes)
    frames = sum(x["summary"].get("frames", 0) for x in scenes)
    s["frames"] = frames
    s["framesOverBudget"] = sum(x["summary"].get("framesOverBudget", 0) for x in scenes)
    s["missedDeadlines"] = sum(x["summary"].get("missedDeadlines", 0) for x in scenes)
    s["deadlineSamples"] = sum(x["summary"].get("deadlineSamples", 0) for x in scenes)
    for field in ("gpuPassMeanMs", "gpuPassMinMs", "timingMeanMs"):
        merged = {}
        for x in scenes:
            for label, value in x["summary"].get(field, {}).items():
                merged[label] = min(merged.get(label, value), value)
        s[field] = merged
    s["worstThermalState"] = max(x["summary"].get("worstThermalState", 0) for x in scenes)
    first["runs"] = len(scenes)
    return first


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("summaries", nargs="+")
    ap.add_argument("--baselines", default=os.path.join(os.path.dirname(__file__), "..", "..", "perf", "baselines"))
    ap.add_argument("--update", action="store_true", help="write these runs as the baseline")
    ap.add_argument("--time-tolerance", type=float, default=0.10, help="relative slack for frame and system time metrics")
    ap.add_argument("--rate-tolerance", type=float, default=0.005, help="absolute slack for over-budget and missed-deadline rates")
    ap.add_argument("--pass-tolerance", type=float, default=0.20, help="relative slack for per-pass GPU minimums")
    args = ap.parse_args()

    runs = [load(p) for p in args.summaries]
    first = runs[0]
    for run in runs[1:]:
        if config_key(run["render"]) != config_key(first["render"]) or run["device"]["model"] != first["device"]["model"]:
            print("summaries come from different devices or render configurations; refusing to aggregate")
            return 2
    scenes_by_id = {}
    for run in runs:
        for scene in run["scenes"]:
            scenes_by_id.setdefault(scene["id"], []).append(scene)
    scenes = [aggregate(group) for group in scenes_by_id.values()]

    model = safe_model(first["device"]["model"])
    platform = first["render"]["platform"]
    base_dir = os.path.join(args.baselines, model, platform)
    r = first["render"]
    print(f"{len(runs)} run(s), label={first.get('label','')!r} device={first['device']['model']} platform={platform} "
          f"viewport={r.get('viewportWidth')}x{r.get('viewportHeight')} x{r.get('viewCount')} refresh={r.get('displayRefreshHz')}")

    if args.update:
        os.makedirs(base_dir, exist_ok=True)
        for scene in scenes:
            record = {"render": first["render"], "device": first["device"], "label": first.get("label", ""),
                      "runIDs": [run["runID"] for run in runs], "scene": scene}
            with open(os.path.join(base_dir, f"{scene['id']}.json"), "w") as f:
                json.dump(record, f, indent=2, sort_keys=True)
        print(f"baseline written to {base_dir} for {len(scenes)} scene(s) from {len(runs)} run(s)")
        return 0

    regressions = 0
    for scene in scenes:
        path = os.path.join(base_dir, f"{scene['id']}.json")
        s = scene["summary"]
        over = rate(s.get("framesOverBudget", 0), s.get("frames", 0))
        missed = rate(s.get("missedDeadlines", 0), s.get("deadlineSamples", 0))
        head = (f"{scene['id']}: frames {s.get('frames',0)} p95 {s.get('p95FrameMs',0):.2f} p99 {s.get('p99FrameMs',0):.2f} "
                f"gpu {s.get('meanGPUExecutionMs',0):.2f} overBudget {over*100:.2f}% missed {missed*100:.2f}%")
        if not os.path.exists(path):
            print(f"{head}  [no baseline]")
            continue
        base = load(path)
        if config_key(base["render"]) != config_key(first["render"]):
            print(f"{head}  [baseline has a different render configuration, skipped]")
            continue
        b = base["scene"]["summary"]
        bover = rate(b.get("framesOverBudget", 0), b.get("frames", 0))
        bmissed = rate(b.get("missedDeadlines", 0), b.get("deadlineSamples", 0))
        print(head)

        def judge(label, now, ref, tolerance, unit="ms", relative=True):
            nonlocal regressions
            if relative:
                if ref <= 0:
                    return
                delta = (now - ref) / ref
                flag = "REGRESSION" if delta > tolerance else ("better" if delta < -tolerance else "ok")
                print(f"    {label:28s} {now:9.3f} vs {ref:9.3f} {unit} {delta*100:+7.1f}%  {flag}")
            else:
                delta = now - ref
                flag = "REGRESSION" if delta > tolerance else "ok"
                print(f"    {label:28s} {now*100:8.2f}% vs {ref*100:8.2f}%  {delta*100:+6.2f}pt  {flag}")
            if flag == "REGRESSION":
                regressions += 1

        for key, label in FRAME_METRICS:
            judge(label, s.get(key, 0.0), b.get(key, 0.0), args.time_tolerance)
        for key, label in INFO_METRICS:
            now, ref = s.get(key, 0.0), b.get(key, 0.0)
            if ref > 0:
                print(f"    {label:28s} {now:9.3f} vs {ref:9.3f} ms {(now-ref)/ref*100:+7.1f}%  (info)")
        judge("overBudgetRate", over, bover, args.rate_tolerance, relative=False)
        judge("missedDeadlineRate", missed, bmissed, args.rate_tolerance, relative=False)
        tnow, tref = s.get("timingMeanMs", {}), b.get("timingMeanMs", {})
        for field in TIMING_FIELDS:
            if field in tnow and field in tref and tref[field] >= 0.02:
                judge(f"cpu {field}", tnow[field], tref[field], args.time_tolerance)
        pnow, pref = s.get("gpuPassMinMs", {}), b.get("gpuPassMinMs", {})
        for label in sorted(pref):
            if label in pnow and pref[label] >= 0.05:
                judge(f"gpu min {label[:20]}", pnow[label], pref[label], args.pass_tolerance)
    if regressions:
        print(f"{regressions} regression(s)")
        return 1
    print("no regressions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
