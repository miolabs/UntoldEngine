#!/usr/bin/env python3
"""Compare a PerfBench summary.json against the stored baseline for the same device model.

Baselines live in perf/baselines/<model>/<platform>/<scene>.json and hold the scene result as the
app wrote it, so a baseline is only ever compared with the same platform, layout, foveation and
viewport. Exit status 1 means at least one metric regressed past its threshold.

    compare_baseline.py perf/results/<run>/summary.json [--baselines DIR] [--update]
                        [--time-tolerance 0.10] [--rate-tolerance 0.005]
"""
import argparse
import json
import os
import sys

TIME_METRICS = [
    ("p95FrameMs", "p95 frame ms"),
    ("p99FrameMs", "p99 frame ms"),
    ("meanFrameMs", "mean frame ms"),
    ("meanGPUExecutionMs", "mean GPU ms"),
]


def load(path):
    with open(path) as f:
        return json.load(f)


def safe_model(name):
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in name)


def rate(numerator, denominator):
    return (numerator / denominator) if denominator else 0.0


def scene_rates(scene):
    s = scene["summary"]
    frames = s.get("frames", 0)
    return {
        "overBudgetRate": rate(s.get("framesOverBudget", 0), frames),
        "missedDeadlineRate": rate(s.get("missedDeadlines", 0), s.get("deadlineSamples", 0)),
    }


def config_key(summary):
    r = summary["render"]
    return (r["platform"], r.get("layout"), r.get("foveation"), r.get("viewportWidth"), r.get("viewportHeight"), r.get("viewCount"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("summary")
    ap.add_argument("--baselines", default=os.path.join(os.path.dirname(__file__), "..", "..", "perf", "baselines"))
    ap.add_argument("--update", action="store_true", help="write this run as the baseline")
    ap.add_argument("--time-tolerance", type=float, default=0.10, help="relative slack for time metrics")
    ap.add_argument("--rate-tolerance", type=float, default=0.005, help="absolute slack for over-budget and missed-deadline rates")
    ap.add_argument("--pass-tolerance", type=float, default=0.20, help="relative slack for per-pass GPU means")
    args = ap.parse_args()

    run = load(args.summary)
    model = safe_model(run["device"]["model"])
    platform = run["render"]["platform"]
    base_dir = os.path.join(args.baselines, model, platform)
    print(f"run {run['runID']} label={run.get('label','')!r} device={run['device']['model']} platform={platform} "
          f"viewport={run['render'].get('viewportWidth')}x{run['render'].get('viewportHeight')} x{run['render'].get('viewCount')}")

    if args.update:
        os.makedirs(base_dir, exist_ok=True)
        for scene in run["scenes"]:
            record = {"render": run["render"], "device": run["device"], "label": run.get("label", ""),
                      "runID": run["runID"], "scene": scene}
            with open(os.path.join(base_dir, f"{scene['id']}.json"), "w") as f:
                json.dump(record, f, indent=2, sort_keys=True)
        print(f"baseline written to {base_dir} for {len(run['scenes'])} scene(s)")
        return 0

    regressions = 0
    for scene in run["scenes"]:
        path = os.path.join(base_dir, f"{scene['id']}.json")
        s = scene["summary"]
        rates = scene_rates(scene)
        head = f"{scene['id']}: frames {s.get('frames',0)} p95 {s.get('p95FrameMs',0):.2f} p99 {s.get('p99FrameMs',0):.2f} " \
               f"gpu {s.get('meanGPUExecutionMs',0):.2f} overBudget {rates['overBudgetRate']*100:.2f}% missed {rates['missedDeadlineRate']*100:.2f}%"
        if not os.path.exists(path):
            print(f"{head}  [no baseline]")
            continue
        base = load(path)
        if config_key({"render": base["render"]}) != config_key(run):
            print(f"{head}  [baseline has a different render configuration, skipped]")
            continue
        b = base["scene"]["summary"]
        brates = scene_rates(base["scene"])
        print(head)
        for key, label in TIME_METRICS:
            now, ref = s.get(key, 0.0), b.get(key, 0.0)
            if ref <= 0:
                continue
            delta = (now - ref) / ref
            flag = "REGRESSION" if delta > args.time_tolerance else ("better" if delta < -args.time_tolerance else "ok")
            if flag == "REGRESSION":
                regressions += 1
            print(f"    {label:14s} {now:8.2f} vs {ref:8.2f}  {delta*100:+6.1f}%  {flag}")
        for key in ("overBudgetRate", "missedDeadlineRate"):
            now, ref = rates[key], brates[key]
            delta = now - ref
            flag = "REGRESSION" if delta > args.rate_tolerance else "ok"
            if flag == "REGRESSION":
                regressions += 1
            print(f"    {key:14s} {now*100:7.2f}% vs {ref*100:7.2f}%  {delta*100:+6.2f}pt  {flag}")
        passes_now = s.get("gpuPassMeanMs", {})
        passes_ref = b.get("gpuPassMeanMs", {})
        for label in sorted(passes_ref):
            ref = passes_ref[label]
            now = passes_now.get(label)
            if now is None or ref < 0.05:
                continue
            delta = (now - ref) / ref
            if delta > args.pass_tolerance:
                regressions += 1
                print(f"    pass {label!r}: {now:.3f} vs {ref:.3f} ms  {delta*100:+6.1f}%  REGRESSION")
    if regressions:
        print(f"{regressions} regression(s)")
        return 1
    print("no regressions")
    return 0


if __name__ == "__main__":
    sys.exit(main())
