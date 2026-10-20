#!/usr/bin/env python3
"""Read-only local telemetry adapter; emits the sidecar-compatible JSON shape."""
import json
import subprocess
from pathlib import Path


def memory_percent(meminfo):
    fields = {}
    for line in meminfo.splitlines():
        key, _, value = line.partition(":")
        if value.strip().split():
            try:
                fields[key] = int(value.strip().split()[0])
            except ValueError:
                continue
    total = fields.get("MemTotal", 0)
    available = fields.get("MemAvailable")
    if not total or available is None or not 0 <= available <= total:
        return None
    return round(100 * (total - available) / total, 2)


def gpu_data(run=subprocess.run):
    gpu = {"available": False}
    try:
        result = run(
            ["nvidia-smi", "--query-gpu=temperature.gpu,utilization.gpu,memory.used,memory.total",
             "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=3, check=True)
        values = [int(v.strip()) for v in result.stdout.splitlines()[0].split(",")]
        if len(values) == 4 and -50 <= values[0] <= 200:
            gpu = {"available": True, "temperature_c": values[0],
                   "utilization_percent": values[1], "memory_used_mb": values[2],
                   "memory_total_mb": values[3]}
    except (OSError, ValueError, IndexError, subprocess.SubprocessError):
        pass
    return gpu


def docker_data(run=subprocess.run):
    try:
        result = run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}"],
                     capture_output=True, text=True, timeout=3, check=True)
        containers = []
        for line in result.stdout.splitlines():
            parts = line.split("\t", 1)
            if len(parts) != 2 or not all(parts):
                raise ValueError("Malformed Docker row")
            containers.append({"name": parts[0], "status": parts[1]})
        return {"available": True, "containers": containers}
    except (OSError, ValueError, subprocess.SubprocessError):
        return {"available": False, "containers": []}


def collect(meminfo_path="/proc/meminfo", run=subprocess.run):
    try:
        ram = memory_percent(Path(meminfo_path).read_text())
    except OSError:
        ram = None
    return {"memory": {"percent": ram}, "gpu": gpu_data(run), "docker": docker_data(run),
            "disk": {"percent": None}, "source": "watchman-local-readonly"}


if __name__ == "__main__":
    print(json.dumps(collect(), separators=(",", ":")))
