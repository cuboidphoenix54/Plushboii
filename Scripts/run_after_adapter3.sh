#!/bin/bash
set -euo pipefail

REPOSITORY="$(cd "$(dirname "$0")/.." && pwd)"
TRAINING_ROOT="${1:-/Volumes/AMITA/PlushboiiTraining}"
TRAINING_PID="${2:-57095}"
TRAINING_LOG="$TRAINING_ROOT/train3.log"
OUTPUT="$TRAINING_ROOT/anatomy4"
ADAPTER="$TRAINING_ROOT/adapter4"
LOCK="$TRAINING_ROOT/.anatomy4_pipeline.lock"
STATUS_FILE="$TRAINING_ROOT/anatomy4_pipeline.status"
STATUS="WAITING_FOR_ADAPTER3"

if [ ! -d "$TRAINING_ROOT" ]; then
    printf 'Training directory is not mounted: %s\n' "$TRAINING_ROOT" >&2
    exit 1
fi

exec >> "$TRAINING_ROOT/anatomy4_pipeline.log" 2>&1

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

if [ -f "$STATUS_FILE" ]; then
    STATUS="$(cat "$STATUS_FILE")"
fi

if [ "$STATUS" = "DONE" ]; then
    log "The anatomy4 pipeline has already completed; refusing to run twice."
    exit 0
fi
if [ "$STATUS" = "DATASET_INCOMPLETE" ]; then
    log "The dataset directory is incomplete and is preserved for manual review."
    exit 1
fi

if ! mkdir "$LOCK" 2>/dev/null; then
    log "Another anatomy4 pipeline watcher owns the lock."
    exit 1
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

if [ "$STATUS" = "WAITING_FOR_ADAPTER3" ]; then
    printf 'WAITING_FOR_ADAPTER3\n' > "$STATUS_FILE"
    log "Waiting for adapter3 trainer PID $TRAINING_PID to finish."

    while true; do
        COMMAND="$(ps -p "$TRAINING_PID" -o command= 2>/dev/null || true)"
        if [[ "$COMMAND" == *"$TRAINING_ROOT/run_train.py"* && "$COMMAND" == *"$TRAINING_ROOT/adapter3"* ]]; then
            sleep 60
            continue
        fi
        break
    done
fi

if ! grep -Fq "Saved final trainable weights to $TRAINING_ROOT/adapter3/adapters.safetensors" "$TRAINING_LOG" \
    || [ ! -s "$TRAINING_ROOT/adapter3/adapters.safetensors" ]; then
    printf 'ADAPTER3_INCOMPLETE\n' > "$STATUS_FILE"
    log "Adapter3 exited without a confirmed final-weights save; not starting another run."
    exit 1
fi
STATUS="WAITING_FOR_ADAPTER3"

export HF_HOME="$TRAINING_ROOT/hf"
export TMPDIR="$TRAINING_ROOT/tmp"
mkdir -p "$TMPDIR"

if [ "$STATUS" = "WAITING_FOR_ADAPTER3" ]; then
    if [ -e "$OUTPUT" ] || [ -e "$ADAPTER" ]; then
        if [ ! -s "$OUTPUT/manifest.json" ]; then
            printf 'DATASET_INCOMPLETE\n' > "$STATUS_FILE"
            log "An existing anatomy4 output is incomplete; refusing to overwrite it."
            exit 1
        fi
        log "Found the validated anatomy4 dataset; continuing without regenerating it."
    else
        printf 'GENERATING_DATASET\n' > "$STATUS_FILE"
        log "Generating a versioned 2,000-candidate anatomy4 corpus with geometry-backed labels."
        nice -n 10 "$REPOSITORY/.build/release/plushdata" "$OUTPUT" --count 2000 --seed 420
    fi
fi

if [ "$STATUS" = "GENERATING_DATASET" ] && [ ! -s "$OUTPUT/manifest.json" ]; then
    printf 'DATASET_INCOMPLETE\n' > "$STATUS_FILE"
    log "Dataset generation was interrupted before a manifest was written; refusing to overwrite partial output."
    exit 1
fi
if [ ! -s "$OUTPUT/manifest.json" ]; then
    printf 'DATASET_INCOMPLETE\n' > "$STATUS_FILE"
    log "The anatomy4 dataset manifest is missing; refusing to train on incomplete data."
    exit 1
fi

python3 - "$OUTPUT/manifest.json" <<'PY'
import json
import sys

manifest = json.load(open(sys.argv[1], encoding="utf-8"))
if manifest["written"] < 100:
    raise SystemExit(f"Too few validated examples were generated: {manifest['written']}")
if not all(manifest[key] > 0 for key in ("train", "validation", "test")):
    raise SystemExit("A train, validation, or test split is empty.")
print(json.dumps(manifest, sort_keys=True))
PY

if [ "$STATUS" != "EVALUATING_ADAPTER4" ] && [ "$STATUS" != "TRAINING_ADAPTER4" ]; then
    STATUS="TRAINING_ADAPTER4"
    printf '%s\n' "$STATUS" > "$STATUS_FILE"
fi

if [ "$STATUS" = "TRAINING_ADAPTER4" ]; then
    if grep -Fq "Saved final trainable weights to $ADAPTER/adapters.safetensors" "$TRAINING_ROOT/train4.log" \
        && [ -s "$ADAPTER/adapters.safetensors" ]; then
        log "Adapter4 already has a verified final save; skipping training."
    elif [ -d "$ADAPTER" ] && find "$ADAPTER" -maxdepth 1 -type f -name '[0-9]*_adapters.safetensors' -print -quit | grep -q .; then
        log "Resuming interrupted adapter4 from its newest saved adapter checkpoint."
        "$TRAINING_ROOT/venv/bin/python" "$REPOSITORY/Scripts/recover_mlx_training.py" \
            "$TRAINING_ROOT" 4 "$OUTPUT" "$ADAPTER" \
            >> "$TRAINING_ROOT/train4_recovery.log" 2>&1
    elif [ -e "$ADAPTER/adapters.safetensors" ]; then
        printf 'ADAPTER4_INCOMPLETE\n' > "$STATUS_FILE"
        log "Adapter4 has weights but no verified completion marker or resumable checkpoint."
        exit 1
    else
        mkdir -p "$ADAPTER"
        log "Starting adapter4 training."
        "$TRAINING_ROOT/venv/bin/python" "$TRAINING_ROOT/run_train.py" \
            --model mlx-community/gemma-4-e4b-it-4bit \
            --data "$OUTPUT" \
            --train-type lora \
            --epochs 2 \
            --learning-rate 1e-4 \
            --lora-rank 32 \
            --batch-size 1 \
            --steps-per-report 10 \
            --steps-per-eval 100 \
            --steps-per-save 100 \
            --val-batches 12 \
            --grad-checkpoint \
            --max-seq-length 2304 \
            --train-on-completions \
            --output-path "$ADAPTER" \
            > "$TRAINING_ROOT/train4.log" 2>&1
    fi
fi

if [ ! -s "$ADAPTER/adapters.safetensors" ]; then
    printf 'ADAPTER4_INCOMPLETE\n' > "$STATUS_FILE"
    log "Adapter4 training exited without final adapter weights; skipping evaluation."
    exit 1
fi

printf 'EVALUATING_ADAPTER4\n' > "$STATUS_FILE"
log "Evaluating adapter4 on the held-out anatomy4 validation split."
if ! curl -fsS --max-time 3 http://127.0.0.1:8080/health >/dev/null; then
    log "No healthy MLX server is available; starting one with adapter4."
    "$TRAINING_ROOT/venv/bin/python" "$TRAINING_ROOT/run_server.py" \
        --host 127.0.0.1 \
        --port 8080 \
        --model mlx-community/gemma-4-e4b-it-4bit \
        --adapter-path "$ADAPTER" \
        > "$TRAINING_ROOT/server4.log" 2>&1 &
    SERVER_PID=$!
    for attempt in $(seq 1 90); do
        if curl -fsS --max-time 3 http://127.0.0.1:8080/health >/dev/null; then
            break
        fi
        sleep 2
    done
    if ! curl -fsS --max-time 3 http://127.0.0.1:8080/health >/dev/null; then
        printf 'SERVER_UNAVAILABLE\n' > "$STATUS_FILE"
        log "The MLX server did not become healthy; evaluation was not run."
        exit 1
    fi
fi

"$TRAINING_ROOT/venv/bin/python" "$REPOSITORY/Scripts/evaluate_mlx_anatomy.py" \
    "$OUTPUT" "$ADAPTER" \
    > "$TRAINING_ROOT/eval4.log" 2>&1

printf 'DONE\n' > "$STATUS_FILE"
log "Dataset generation, adapter4 training, and held-out evaluation completed."
