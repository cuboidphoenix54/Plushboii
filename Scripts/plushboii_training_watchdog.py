#!/usr/bin/env python3
"""Reconnect the training volume, recover interrupted runs, and report update/data candidates."""

import argparse
import fcntl
import json
import os
import plistlib
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


INTERVAL_SECONDS = 300
REPORT_INTERVAL_SECONDS = 24 * 60 * 60
ADAPTER3_FINAL_MARKER = "Saved final trainable weights to"


def run(command, *, timeout=30, check=False):
    return subprocess.run(
        command, capture_output=True, text=True, timeout=timeout, check=check
    )


def log(message):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}", flush=True)


def walk_disk_records(record):
    yield record
    for key in ("Partitions", "AllDisksAndPartitions"):
        children = record.get(key, [])
        if isinstance(children, list):
            for child in children:
                if isinstance(child, dict):
                    yield from walk_disk_records(child)


def find_volume_device(volume_uuid):
    result = run(["/usr/sbin/diskutil", "list", "-plist"], timeout=20)
    if result.returncode:
        raise RuntimeError(f"diskutil list failed: {result.stderr.strip()}")
    disks = plistlib.loads(result.stdout.encode())
    for record in walk_disk_records(disks):
        identifier = record.get("DeviceIdentifier")
        if not identifier:
            continue
        info = run(["/usr/sbin/diskutil", "info", "-plist", identifier], timeout=15)
        if info.returncode:
            continue
        try:
            details = plistlib.loads(info.stdout.encode())
        except plistlib.InvalidFileException:
            continue
        if details.get("VolumeUUID", "").upper() == volume_uuid.upper():
            return identifier, details
    return None, None


def ensure_volume(volume_uuid, expected_mount):
    current = Path(expected_mount)
    if current.is_dir():
        result = run(["/usr/sbin/diskutil", "info", "-plist", str(current)])
        if result.returncode == 0:
            details = plistlib.loads(result.stdout.encode())
            if details.get("VolumeUUID", "").upper() == volume_uuid.upper():
                return True

    identifier, details = find_volume_device(volume_uuid)
    if not identifier:
        log(f"Waiting for external volume UUID {volume_uuid} to reconnect.")
        return False
    if details.get("MountPoint"):
        log(f"Expected SSD is mounted at {details['MountPoint']}, not {expected_mount}.")
        return Path(details["MountPoint"]).resolve() == current.resolve()

    mount = run(["/usr/sbin/diskutil", "mount", identifier], timeout=60)
    if mount.returncode:
        log(f"Could not mount expected SSD: {mount.stderr.strip() or mount.stdout.strip()}")
        return False
    log(f"Mounted expected SSD {identifier} at {expected_mount}.")
    return current.is_dir()


def processes():
    result = run(["/bin/ps", "-axo", "pid=,command="])
    found = []
    for line in result.stdout.splitlines():
        match = re.match(r"\s*(\d+)\s+(.*)", line)
        if match:
            found.append((int(match.group(1)), match.group(2)))
    return found


def active_training_or_pipeline(training_root):
    root = str(training_root)
    for pid, command in processes():
        if pid == os.getpid():
            continue
        if "run_train.py" in command and root in command:
            return f"trainer PID {pid}"
        if "run_after_adapter3.sh" in command and root in command:
            return f"pipeline PID {pid}"
    return None


def request_json(url, *, timeout=20):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "Plushboii-Training-Watchdog/1.0"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def discover_public_datasets():
    results = []
    queries = ("3d mesh", "3d object mesh", "textured 3d model")
    for query in queries:
        url = "https://huggingface.co/api/datasets?" + urllib.parse.urlencode(
            {"search": query, "limit": 50, "full": "true"}
        )
        try:
            records = request_json(url)
        except (OSError, ValueError, urllib.error.URLError) as error:
            log(f"Public dataset metadata lookup failed for {query!r}: {error}")
            continue
        for record in records:
            card = record.get("cardData") or {}
            tags = record.get("tags") or []
            license_tag = next((tag[8:] for tag in tags if tag.startswith("license:")), None)
            license_name = card.get("license") or license_tag
            results.append(
                {
                    "id": record.get("id"),
                    "url": f"https://huggingface.co/datasets/{record.get('id', '')}",
                    "license": license_name,
                    "license_verified": bool(license_name),
                    "downloads": record.get("downloads"),
                    "tags": tags[:30],
                    "query": query,
                }
            )
    unique = {}
    for candidate in results:
        if candidate["id"]:
            unique[candidate["id"]] = candidate
    return sorted(
        unique.values(),
        key=lambda item: (not item["license_verified"], -(item["downloads"] or 0)),
    )


def local_dataset_inventory(training_root):
    entries = []
    for directory in sorted(training_root.glob("anatomy*")):
        if not directory.is_dir():
            continue
        manifest_path = directory / "manifest.json"
        manifest = None
        if manifest_path.is_file():
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                manifest = {"error": "manifest unreadable"}
        entries.append(
            {
                "path": str(directory),
                "manifest": manifest,
                "splits": {
                    name: (directory / f"{name}.jsonl").is_file()
                    for name in ("train", "valid", "test")
                },
            }
        )
    return entries


def write_discovery_reports(training_root, state_dir, state):
    now = time.time()
    if now - state.get("last_discovery", 0) < REPORT_INTERVAL_SECONDS:
        return
    log("Checking installed Python package updates and public dataset metadata.")
    environment = os.environ.copy()
    environment["HF_HOME"] = str(training_root / "hf")
    environment["TMPDIR"] = str(training_root / "tmp")
    python = training_root / "venv/bin/python"
    update_report = {"checked_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}
    try:
        result = subprocess.run(
            [str(python), "-m", "pip", "list", "--outdated", "--format=json"],
            capture_output=True,
            text=True,
            timeout=180,
            env=environment,
        )
        if result.returncode == 0:
            update_report["outdated_packages"] = json.loads(result.stdout)
        else:
            update_report["error"] = result.stderr[-2000:]
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        update_report["error"] = str(error)

    dataset_report = {
        "checked_at": update_report["checked_at"],
        "local_datasets": local_dataset_inventory(training_root),
        "public_metadata_only": True,
        "candidates": discover_public_datasets(),
        "policy": "No files are downloaded or added to training automatically.",
    }
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "software_updates.json").write_text(
        json.dumps(update_report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (state_dir / "training_data_candidates.json").write_text(
        json.dumps(dataset_report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    report_dir = training_root / "watchdog-reports"
    report_dir.mkdir(exist_ok=True)
    (report_dir / "software_updates.json").write_text(
        json.dumps(update_report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (report_dir / "training_data_candidates.json").write_text(
        json.dumps(dataset_report, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    state["last_discovery"] = now


def adapter3_is_complete(training_root):
    log_path = training_root / "train3.log"
    weights = training_root / "adapter3/adapters.safetensors"
    return (
        log_path.is_file()
        and ADAPTER3_FINAL_MARKER in log_path.read_text(errors="replace")
        and weights.is_file()
        and weights.stat().st_size > 0
    )


def recover_adapter3(training_root, repo_root):
    log("Adapter3 has no verified final save; attempting checkpoint recovery.")
    helper = repo_root / "Scripts/recover_mlx_training.py"
    command = [
        sys.executable,
        str(helper),
        str(training_root),
        "3",
        str(training_root / "anatomy3"),
        str(training_root / "adapter3"),
    ]
    result = subprocess.run(command, cwd=repo_root)
    if result.returncode:
        log(f"Adapter3 recovery stopped with exit code {result.returncode}.")
        return False
    return adapter3_is_complete(training_root)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--training-root", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--volume-uuid", required=True)
    parser.add_argument("--mount-point", default="/Volumes/AMITA")
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    training_root = Path(args.training_root)
    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)

    with (state_dir / "watchdog.lock").open("w") as lock_file:
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            log("Another watchdog invocation is active; skipping this interval.")
            return

        if not ensure_volume(args.volume_uuid, args.mount_point):
            return
        if args.check_only:
            log("Volume identity and mount check succeeded; no training or discovery action was run.")
            return
        if not (training_root / "venv/bin/python").is_file():
            log(f"Training environment is missing under {training_root}.")
            return

        state_path = state_dir / "state.json"
        try:
            state = json.loads(state_path.read_text()) if state_path.exists() else {}
        except (OSError, ValueError):
            log(f"Unreadable watchdog state at {state_path}; refusing to reset it.")
            return
        pipeline_status = training_root / "anatomy4_pipeline.status"
        if pipeline_status.is_file():
            try:
                status = pipeline_status.read_text(encoding="utf-8").strip()
            except OSError as error:
                log(f"Cannot read pipeline status: {error}")
                return
            if status == "DONE":
                log("The queued pipeline is complete; no further training action is needed.")
                return
            if status == "DATASET_INCOMPLETE":
                log("The generated dataset is incomplete and preserved for manual review.")
                return
        try:
            write_discovery_reports(training_root, state_dir, state)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            log(f"Discovery report update failed: {error}")

        active = active_training_or_pipeline(training_root)
        if active:
            log(f"Existing {active} is active; it will be left undisturbed.")
        else:
            if not adapter3_is_complete(training_root):
                if not recover_adapter3(training_root, Path(args.repo_root)):
                    state_path.write_text(json.dumps(state, indent=2) + "\n")
                    return

            log("Starting the guarded queued anatomy4 pipeline.")
            result = subprocess.run(
                [
                    "/bin/bash",
                    str(Path(args.repo_root) / "Scripts/run_after_adapter3.sh"),
                    str(training_root),
                    "57095",
                ],
                cwd=args.repo_root,
            )
            if result.returncode:
                log(f"Queued pipeline exited with code {result.returncode}; will re-check next interval.")
        state_path.write_text(json.dumps(state, indent=2) + "\n")


if __name__ == "__main__":
    main()
