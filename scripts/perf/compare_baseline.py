#!/usr/bin/env python3
"""Compare PerfBench run summaries against the stored baseline for the same device model.

Baselines live in perf/baselines/<model>/<platform>/<scene>.json and hold the scene result as the
app wrote it, so a baseline is only ever compared with the same platform, layout, foveation and
viewport. Exit status 1 means at least one metric regressed past its threshold.

Several summaries may be given (repeated runs): every time metric and every rate is aggregated by
its minimum across runs. On a lightly loaded machine CPU and GPU clocks drift between runs, and
other activity on the machine makes it skip refreshes; both only ever inflate a time or a rate, so
the minimum over a few runs is the stable number, and a real regression raises it in every run.

GPU times of a scene that leaves the GPU mostly idle follow the GPU's clock state more than the
workload (the same build measured 0.8 and 2.2 ms for one frame in consecutive runs). They are
judged only when the baseline shows the GPU busy for at least --gpu-busy-fraction of the frame, as
it is on a headset, and reported as information otherwise. A GPU or CPU time also only counts as
changed when it moves by more than the relative tolerance and by more than an absolute slack.

    compare_baseline.py perf/results/<run>/summary.json [more summary.json ...]
                        [--baselines DIR] [--update]
                        [--time-tolerance 0.10] [--rate-tolerance 0.005] [--pass-tolerance 0.20]
                        [--gpu-slack-ms 0.5] [--pass-slack-ms 0.25] [--cpu-slack-ms 0.1]
                        [--gpu-busy-fraction 0.5]
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


# Render settings a baseline must share with a run to be compared with it, with the value assumed
# for records written before the field existed.
CONFIG_FIELDS = [
    ("platform", None), ("layout", None), ("foveation", None), ("viewportWidth", None),
    ("viewportHeight", None), ("viewCount", None), ("antiAliasing", "fxaa"),
    # Frames are display-paced, and the GPU stretches its work over the slack a slower display
    # leaves, so times taken at different refresh rates are not comparable.
    ("displayRefreshHz", 0.0),
    # visionOS: whether the frame pacer may start the submission phase early. It moves the deadline
    # margin and the miss rate, which are judged.
    ("xrFramePacing", False),
    # A build with ENGINE_LOCK_DIAGNOSTICS counts and times every engine lock, so its frame and
    # CPU times are not comparable with a normal build's.
    ("lockDiagnostics", False),
]


def config_key(render):
    return tuple(render.get(name, default) for name, default in CONFIG_FIELDS)


def config_difference(a, b):
    """The render settings in which two records differ, as text."""
    parts = []
    for name, default in CONFIG_FIELDS:
        left, right = a.get(name, default), b.get(name, default)
        if left != right:
            parts.append(f"{name} {left} vs {right}")
    return ", ".join(parts)


def scene_rates(summary):
    """(over-budget rate, missed-deadline rate) of a scene summary, single run or aggregate."""
    over = summary.get("overBudgetRate")
    if over is None:
        over = rate(summary.get("framesOverBudget", 0), summary.get("frames", 0))
    missed = summary.get("missedDeadlineRate")
    if missed is None:
        missed = rate(summary.get("missedDeadlines", 0), summary.get("deadlineSamples", 0))
    return over, missed


def aggregate(scenes):
    """Fold the same scene from several runs into one record: min of times and of rates."""
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
    # The counts above are totals, for the record; the rates that are judged are the best run's.
    s["overBudgetRate"] = min(scene_rates(x["summary"])[0] for x in scenes)
    s["missedDeadlineRate"] = min(scene_rates(x["summary"])[1] for x in scenes)
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
    ap.add_argument("--gpu-slack-ms", type=float, default=0.5, help="a frame's minimum GPU time must also move by more than this")
    ap.add_argument("--pass-slack-ms", type=float, default=0.25, help="a per-pass GPU minimum must also move by more than this")
    ap.add_argument("--cpu-slack-ms", type=float, default=0.1, help="a per-system CPU mean must also move by more than this")
    ap.add_argument("--gpu-busy-fraction", type=float, default=0.5,
                    help="judge GPU times only when the baseline's mean GPU time is at least this fraction of its mean frame time")
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
        over, missed = scene_rates(s)
        head = (f"{scene['id']}: frames {s.get('frames',0)} p95 {s.get('p95FrameMs',0):.2f} p99 {s.get('p99FrameMs',0):.2f} "
                f"gpu {s.get('meanGPUExecutionMs',0):.2f} overBudget {over*100:.2f}% missed {missed*100:.2f}%")
        if not os.path.exists(path):
            print(f"{head}  [no baseline]")
            continue
        base = load(path)
        if config_key(base["render"]) != config_key(first["render"]):
            difference = config_difference(base["render"], first["render"])
            print(f"{head}  [baseline has a different render configuration ({difference}), skipped]")
            continue
        b = base["scene"]["summary"]
        bover, bmissed = scene_rates(b)
        print(head)

        # With the GPU idle most of the frame its times follow the clock state, not the workload.
        gpu_busy = rate(b.get("meanGPUExecutionMs", 0.0), b.get("meanFrameMs", 0.0)) >= args.gpu_busy_fraction

        def judge(label, now, ref, tolerance, unit="ms", relative=True, slack=0.0, informational=False):
            nonlocal regressions
            if relative:
                if ref <= 0:
                    return
                delta = (now - ref) / ref
                if informational:
                    print(f"    {label:28s} {now:9.3f} vs {ref:9.3f} {unit} {delta*100:+7.1f}%  (info, GPU mostly idle)")
                    return
                moved = abs(now - ref) > slack
                flag = "REGRESSION" if delta > tolerance and moved else ("better" if delta < -tolerance and moved else "ok")
                print(f"    {label:28s} {now:9.3f} vs {ref:9.3f} {unit} {delta*100:+7.1f}%  {flag}")
            else:
                delta = now - ref
                flag = "REGRESSION" if delta > tolerance else "ok"
                print(f"    {label:28s} {now*100:8.2f}% vs {ref*100:8.2f}%  {delta*100:+6.2f}pt  {flag}")
            if flag == "REGRESSION":
                regressions += 1

        for key, label in FRAME_METRICS:
            is_gpu = key == "minGPUExecutionMs"
            judge(label, s.get(key, 0.0), b.get(key, 0.0), args.time_tolerance,
                  slack=args.gpu_slack_ms if is_gpu else 0.0, informational=is_gpu and not gpu_busy)
        for key, label in INFO_METRICS:
            now, ref = s.get(key, 0.0), b.get(key, 0.0)
            if ref > 0:
                print(f"    {label:28s} {now:9.3f} vs {ref:9.3f} ms {(now-ref)/ref*100:+7.1f}%  (info)")
        judge("overBudgetRate", over, bover, args.rate_tolerance, relative=False)
        judge("missedDeadlineRate", missed, bmissed, args.rate_tolerance, relative=False)
        tnow, tref = s.get("timingMeanMs", {}), b.get("timingMeanMs", {})
        for field in TIMING_FIELDS:
            if field in tnow and field in tref and tref[field] >= 0.02:
                judge(f"cpu {field}", tnow[field], tref[field], args.time_tolerance, slack=args.cpu_slack_ms)
        pnow, pref = s.get("gpuPassMinMs", {}), b.get("gpuPassMinMs", {})
        for label in sorted(pref):
            if label in pnow and pref[label] >= 0.05:
                judge(f"gpu min {label[:20]}", pnow[label], pref[label], args.pass_tolerance,
                      slack=args.pass_slack_ms, informational=not gpu_busy)
    if regressions:
        print(f"{regressions} regression(s)")
        return 1
    print("no regressions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
