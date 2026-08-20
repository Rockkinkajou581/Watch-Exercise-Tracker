"""Watch an iCloud Drive folder for new watch exports and auto-retrain the CNN.

The iPhone app exports a merged ``readings.csv`` + ``sets.csv`` (every session
concatenated). You drop those two files into ``training/data/``; this script —
running on your Mac — notices when they change and runs the full pipeline:

    train.py             ->  export_coreml.py        (exercise classifier)
    train_reps_windows.py -> export_reps_coreml.py   (rep counter, if reps.csv)

producing fresh ``artifacts/LiftLoggerClassifier.mlpackage`` and (once you've
collected tap labels) ``artifacts/LiftLoggerRepCounter.mlpackage``, ready to drop
into the Watch target.

Usage (from inside the training/ folder, with the venv active):

    python auto_retrain.py                 # watch forever, poll every 30s
    python auto_retrain.py --once          # run one pass and exit
    python auto_retrain.py --interval 15   # poll every 15s
    python auto_retrain.py --watch-dir ~/SomeOtherFolder

Default watch folder is ``training/data/`` itself. If you point --watch-dir at a
different folder (e.g. an iCloud Drive folder), the CSVs are copied into
``training/data/`` before training; if it's the data folder, they're used in place.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

import config

DEFAULT_WATCH_DIR = config.DATA_DIR     # watch training/data/ directly
REQUIRED = ("readings.csv", "sets.csv")
OPTIONAL = ("reps.csv",)                # per-rep tap labels — trains the rep counter too
STATE_FILE = config.ARTIFACTS / ".auto_retrain_state.json"


def log(msg: str) -> None:
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def ensure_downloaded(path: Path) -> None:
    """iCloud may store a file as a dataless placeholder (.name.icloud) until
    something reads it. Ask the system to materialize it and wait briefly."""
    if path.exists():
        return
    placeholder = path.with_name(f".{path.name}.icloud")
    if placeholder.exists():
        log(f"{path.name} is in iCloud but not downloaded — requesting download")
        subprocess.run(["brctl", "download", str(path)], check=False)
        for _ in range(60):                 # up to ~30s for the download
            if path.exists():
                return
            time.sleep(0.5)


def stable_signature(watch_dir: Path) -> str | None:
    """Return a hash of both CSVs once they exist and have stopped changing.

    iCloud writes can land in pieces, so we read sizes, wait, and only hash when
    they're identical across the gap. Returns None if a file is still missing.
    """
    paths = [watch_dir / name for name in REQUIRED]
    for p in paths:
        ensure_downloaded(p)
        if not p.exists():
            return None

    sizes_before = [p.stat().st_size for p in paths]
    time.sleep(2.0)
    sizes_after = [p.stat().st_size for p in paths]
    if sizes_before != sizes_after:
        log("files still changing (mid-sync) — will retry next poll")
        return None
    if any(s == 0 for s in sizes_after):
        return None

    # Include reps.csv in the signature if present, so new tap labels also retrigger.
    for name in OPTIONAL:
        opt = watch_dir / name
        ensure_downloaded(opt)
        if opt.exists():
            paths.append(opt)

    h = hashlib.sha256()
    for p in paths:
        h.update(p.read_bytes())
    return h.hexdigest()


def load_last_signature() -> str | None:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text()).get("signature")
        except (json.JSONDecodeError, OSError):
            return None
    return None


def save_last_signature(sig: str) -> None:
    config.ARTIFACTS.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(
        {"signature": sig, "trained_at": datetime.now().isoformat()}, indent=2))


def run_pipeline(watch_dir: Path) -> bool:
    """Copy the CSVs into data/ and retrain BOTH models in one pass:

        train.py -> export_coreml.py            (exercise classifier — always)
        train_reps_windows.py -> export_reps_coreml.py   (rep counter — if reps.csv)

    Returns True if the classifier pipeline succeeds. The rep pipeline is best-effort:
    it's skipped without reps.csv and, if it fails (e.g. too few tagged bouts yet), it
    logs and continues rather than failing the whole run. Uses the same interpreter
    that launched this script, so it inherits the active venv.
    """
    config.DATA_DIR.mkdir(parents=True, exist_ok=True)
    if watch_dir.resolve() == config.DATA_DIR.resolve():
        log(f"training on files already in {config.DATA_DIR}")
    else:
        for name in REQUIRED:
            shutil.copy2(watch_dir / name, config.DATA_DIR / name)
        for name in OPTIONAL:                      # copy reps.csv too if it's there
            if (watch_dir / name).exists():
                shutil.copy2(watch_dir / name, config.DATA_DIR / name)
        log(f"copied data -> {config.DATA_DIR}")

    # 1) Exercise classifier — required.
    for script in ("train.py", "export_coreml.py"):
        log(f"running {script} ...")
        result = subprocess.run([sys.executable, script], cwd=config.ROOT)
        if result.returncode != 0:
            log(f"!! {script} failed (exit {result.returncode}) — aborting this run")
            return False
    log(f"classifier -> {config.ARTIFACTS / 'LiftLoggerClassifier.mlpackage'}")

    # 2) Rep counter — only if you've collected tap labels; never fatal.
    if (config.DATA_DIR / "reps.csv").exists():
        # The windowed trainer, not train_reps_model.py: same taps, ~20x the
        # examples per set, and no duration/tempo entanglement. See rep_windows.py.
        for script in ("train_reps_windows.py", "export_reps_coreml.py"):
            log(f"running {script} ...")
            result = subprocess.run([sys.executable, script], cwd=config.ROOT)
            if result.returncode != 0:
                log(f"   rep model step '{script}' skipped/failed (exit {result.returncode}) "
                    "— likely too few tagged bouts yet; classifier is still updated")
                break
        else:
            log(f"rep counter -> {config.ARTIFACTS / 'LiftLoggerRepCounter.mlpackage'}")
    else:
        log("no reps.csv — skipping rep counter (collect taps with the phone rep tagger)")
    return True


def check_once(watch_dir: Path, *, force: bool = False) -> bool:
    """One pass: retrain iff the CSVs are present, stable, and changed.

    Returns True if a retrain ran."""
    sig = stable_signature(watch_dir)
    if sig is None:
        return False
    if not force and sig == load_last_signature():
        return False                        # identical to what we last trained on
    log("new data detected — retraining")
    if run_pipeline(watch_dir):
        save_last_signature(sig)
        return True
    return False


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--watch-dir", type=Path, default=DEFAULT_WATCH_DIR,
                    help="folder to watch for readings.csv + sets.csv")
    ap.add_argument("--interval", type=float, default=30.0,
                    help="seconds between polls (ignored with --once)")
    ap.add_argument("--once", action="store_true",
                    help="run a single pass and exit")
    ap.add_argument("--force", action="store_true",
                    help="retrain even if the data hasn't changed")
    args = ap.parse_args()

    watch_dir = args.watch_dir.expanduser()
    watch_dir.mkdir(parents=True, exist_ok=True)
    log(f"watching {watch_dir}")

    if args.once:
        ran = check_once(watch_dir, force=args.force)
        if not ran:
            log("nothing to do (no new/stable CSVs)")
        return

    forced = args.force
    while True:
        try:
            check_once(watch_dir, force=forced)
            forced = False                  # only force the very first pass
        except KeyboardInterrupt:
            log("stopped")
            return
        except Exception as e:              # keep the watcher alive across hiccups
            log(f"error (will keep watching): {e}")
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
