#!/usr/bin/env python3
"""Resume an interrupted MLX adapter run from its newest saved weight checkpoint."""

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


MODEL = "mlx-community/gemma-4-e4b-it-4bit"
PROGRESS = re.compile(r"(\d+)/(\d+)")


def fail(message):
    print(message, file=sys.stderr, flush=True)
    raise SystemExit(2)


if len(sys.argv) != 5:
    fail("usage: recover_mlx_training.py <training-root> <stage> <dataset> <adapter-dir>")

training_root = Path(sys.argv[1])
stage = sys.argv[2]
dataset = Path(sys.argv[3])
adapter_dir = Path(sys.argv[4])
log_path = training_root / f"train{stage}.log"
trainer = training_root / "run_train.py"
python = training_root / "venv/bin/python"

if stage not in ("3", "4"):
    fail(f"unsupported training stage: {stage}")
if not dataset.is_dir() or not adapter_dir.is_dir() or not log_path.is_file():
    fail(f"missing dataset, adapter directory, or log for stage {stage}")

log_text = log_path.read_text(encoding="utf-8", errors="replace")
progress = PROGRESS.findall(log_text)
if not progress:
    fail(f"cannot determine saved training progress from {log_path}")
_, total_text = progress[-1]
total_steps = int(total_text)

checkpoints = []
for candidate in adapter_dir.glob("*_adapters.safetensors"):
    match = re.fullmatch(r"(\d+)_adapters\.safetensors", candidate.name)
    if match and candidate.is_file() and candidate.stat().st_size:
        checkpoints.append((int(match.group(1)), candidate))
if not checkpoints:
    fail(f"no numbered, non-empty adapter checkpoint found in {adapter_dir}")

checkpoint_step, checkpoint = max(checkpoints, key=lambda item: item[0])
remaining = total_steps - checkpoint_step
if remaining <= 0:
    fail(f"checkpoint step {checkpoint_step} is not before total steps {total_steps}")

state_file = adapter_dir / ".recovery_attempts.json"
try:
    attempts = json.loads(state_file.read_text()).get("attempts", 0) if state_file.exists() else 0
except (OSError, ValueError):
    fail(f"cannot read recovery attempt state: {state_file}")
if attempts >= 3:
    fail(f"automatic recovery limit reached for stage {stage}; review the training log")

attempts += 1
state_file.write_text(json.dumps({"attempts": attempts, "checkpoint_step": checkpoint_step}) + "\n")
recovery_dir = adapter_dir / f"recovery-{attempts}"
if recovery_dir.exists():
    fail(f"recovery output already exists; refusing to overwrite {recovery_dir}")

args = [
    str(python),
    str(trainer),
    "--model",
    MODEL,
    "--data",
    str(dataset),
    "--train-type",
    "lora",
    "--learning-rate",
    "1e-4",
    "--lora-rank",
    "32",
    "--batch-size",
    "1",
    "--steps-per-report",
    "10",
    "--steps-per-eval",
    "100",
    "--steps-per-save",
    "100",
    "--val-batches",
    "12",
    "--grad-checkpoint",
    "--max-seq-length",
    "2304",
    "--train-on-completions",
    "--resume-adapter-file",
    str(checkpoint),
    "--iters",
    str(remaining),
    "--output-path",
    str(recovery_dir),
]
environment = os.environ.copy()
environment["HF_HOME"] = str(training_root / "hf")
environment["TMPDIR"] = str(training_root / "tmp")
Path(environment["TMPDIR"]).mkdir(parents=True, exist_ok=True)

print(
    f"Resuming stage {stage} from checkpoint {checkpoint.name}; "
    f"running {remaining} iterations into {recovery_dir}. "
    "MLX restores adapter weights, not optimizer state.",
    flush=True,
)
result = subprocess.run(args, cwd=training_root, env=environment)
if result.returncode:
    raise SystemExit(result.returncode)

recovered_weights = recovery_dir / "adapters.safetensors"
if not recovered_weights.is_file() or recovered_weights.stat().st_size == 0:
    fail(f"training exited without final adapter weights at {recovered_weights}")

temporary_weights = adapter_dir / ".adapters.recovered.safetensors"
shutil.copy2(recovered_weights, temporary_weights)
os.replace(temporary_weights, adapter_dir / "adapters.safetensors")
with log_path.open("a", encoding="utf-8") as log:
    log.write(
        f"\n[watchdog recovery] Saved final trainable weights to "
        f"{adapter_dir / 'adapters.safetensors'} using checkpoint "
        f"{checkpoint.name}; optimizer state was not restored.\n"
    )
print(f"Recovered final adapter weights into {adapter_dir}", flush=True)
