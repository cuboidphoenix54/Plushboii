#!/bin/bash
set -euo pipefail

REPOSITORY="$(cd "$(dirname "$0")/.." && pwd)"
TRAINING_ROOT="${1:-/Volumes/AMITA/PlushboiiTraining}"
VOLUME_UUID="${2:-841DC1F7-EF1E-3BDC-8254-514E2A48587C}"
PYTHON_EXECUTABLE="${3:-$HOME/miniforge3/bin/python3.12}"
LABEL="com.plushboii.training-watchdog"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/Library/Application Support/Plushboii/TrainingWatchdog"
LOG_DIR="$HOME/Library/Logs/Plushboii"
DOMAIN="gui/$(id -u)"

if [ ! -f "$REPOSITORY/Scripts/plushboii_training_watchdog.py" ]; then
    printf 'Watchdog script is missing from %s\n' "$REPOSITORY" >&2
    exit 1
fi
if [ ! -x "$PYTHON_EXECUTABLE" ]; then
    printf 'Python executable is missing or not executable: %s\n' "$PYTHON_EXECUTABLE" >&2
    exit 1
fi

mkdir -p "$(dirname "$PLIST")" "$STATE_DIR" "$LOG_DIR"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    printf 'LaunchAgent %s is already loaded; inspect it before changing it.\n' "$LABEL" >&2
    exit 1
fi

python3 - "$PLIST" "$REPOSITORY" "$TRAINING_ROOT" "$VOLUME_UUID" "$STATE_DIR" "$LOG_DIR" "$LABEL" "$PYTHON_EXECUTABLE" <<'PY'
import os
import plistlib
import sys
import tempfile

plist_path, repo, training_root, volume_uuid, state_dir, log_dir, label, python = sys.argv[1:]
payload = {
    "Label": label,
    "ProgramArguments": [
        python,
        os.path.join(repo, "Scripts/plushboii_training_watchdog.py"),
        "--training-root",
        training_root,
        "--repo-root",
        repo,
        "--volume-uuid",
        volume_uuid,
        "--mount-point",
        "/Volumes/AMITA",
        "--state-dir",
        state_dir,
    ],
    "RunAtLoad": True,
    "StartInterval": 300,
    "StandardOutPath": os.path.join(log_dir, "training-watchdog.log"),
    "StandardErrorPath": os.path.join(log_dir, "training-watchdog-error.log"),
    "EnvironmentVariables": {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": os.path.expanduser("~"),
    },
}
os.makedirs(os.path.dirname(plist_path), exist_ok=True)
fd, temporary = tempfile.mkstemp(dir=os.path.dirname(plist_path), prefix=".training-watchdog.")
try:
    with os.fdopen(fd, "wb") as stream:
        plistlib.dump(payload, stream, sort_keys=True)
    os.replace(temporary, plist_path)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY

launchctl bootstrap "$DOMAIN" "$PLIST"
printf 'Installed and enabled %s\n' "$PLIST"
printf 'Volume UUID: %s\n' "$VOLUME_UUID"
printf 'Reports: %s\n' "$STATE_DIR"
