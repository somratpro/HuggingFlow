#!/usr/bin/env python3
"""
HuggingFlow state sync — backup/restore DeerFlow runtime data to/from HF Dataset.

Syncs:
  - deerflow.db      (SQLite thread/session database)
  - config.yaml      (generated config, may contain user edits)
  - workspace/       (agent-created files in the sandbox workspace)

Usage:
  deerflow-sync.py restore    — restore from HF Dataset on startup
  deerflow-sync.py sync-once  — push current state to HF Dataset
  deerflow-sync.py loop       — sync-once on an interval (reads SYNC_INTERVAL env)
"""

import json
import os
import sys
import time
import tarfile
import tempfile
import logging
from datetime import datetime, timezone
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger(__name__)

HF_TOKEN          = os.environ.get("HF_TOKEN", "")
BACKUP_REPO       = os.environ.get("BACKUP_DATASET_NAME", "huggingflow-backup")
HF_USERNAME       = os.environ.get("HF_USERNAME", "")
DATA_DIR          = Path(os.environ.get("DEER_FLOW_HOME", "/app/data"))
CONFIG_PATH       = Path(os.environ.get("DEER_FLOW_CONFIG_PATH", DATA_DIR / "config.yaml"))
SYNC_INTERVAL     = int(os.environ.get("SYNC_INTERVAL", "600"))

ARCHIVE_NAME      = "deerflow-state.tar.gz"
SYNC_STATUS_FILE  = "/tmp/huggingflow-sync-status.json"

# Files/dirs to include in the backup archive
BACKUP_TARGETS = [
    DATA_DIR / "deerflow.db",
    DATA_DIR / "workspace",
    DATA_DIR / ".secrets",   # persists AUTH_JWT_SECRET across restarts
    CONFIG_PATH,
]


def _write_status(status: str, message: str):
    try:
        payload = {
            "status": status,
            "message": message,
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
        Path(SYNC_STATUS_FILE).write_text(json.dumps(payload))
    except Exception as exc:
        log.debug("Could not write sync status: %s", exc)


def _get_api():
    if not HF_TOKEN:
        raise RuntimeError("HF_TOKEN not set")
    from huggingface_hub import HfApi
    return HfApi(token=HF_TOKEN)


def _resolve_repo_id(api) -> str:
    if "/" in BACKUP_REPO:
        return BACKUP_REPO
    if HF_USERNAME:
        return f"{HF_USERNAME}/{BACKUP_REPO}"
    user = api.whoami()
    return f"{user['name']}/{BACKUP_REPO}"


def _ensure_repo(api, repo_id: str):
    from huggingface_hub import create_repo
    try:
        create_repo(
            repo_id=repo_id,
            repo_type="dataset",
            private=True,
            token=HF_TOKEN,
            exist_ok=True,
        )
    except Exception as exc:
        log.warning("Could not ensure dataset repo: %s", exc)


def _make_archive(dest: Path):
    with tarfile.open(dest, "w:gz") as tar:
        for target in BACKUP_TARGETS:
            if target.exists():
                arcname = target.relative_to(DATA_DIR.parent)
                tar.add(target, arcname=str(arcname))
                log.debug("  + %s", arcname)


def _extract_archive(src: Path):
    extract_root = DATA_DIR.parent
    with tarfile.open(src, "r:gz") as tar:
        for member in tar.getmembers():
            tar.extract(member, path=extract_root)
    log.info("Extracted state to %s", extract_root)


def restore():
    if not HF_TOKEN:
        log.info("No HF_TOKEN — skipping restore.")
        return

    try:
        api = _get_api()
        repo_id = _resolve_repo_id(api)
        _ensure_repo(api, repo_id)

        from huggingface_hub import hf_hub_download
        with tempfile.TemporaryDirectory() as tmp:
            try:
                local = hf_hub_download(
                    repo_id=repo_id,
                    filename=ARCHIVE_NAME,
                    repo_type="dataset",
                    token=HF_TOKEN,
                    local_dir=tmp,
                )
                _extract_archive(Path(local))
                log.info("State restored from %s", repo_id)
                _write_status("restored", f"State restored from {repo_id}")
            except Exception as exc:
                if "404" in str(exc) or "not found" in str(exc).lower() or "does not exist" in str(exc).lower():
                    log.info("No existing backup found in %s — starting fresh.", repo_id)
                    _write_status("configured", f"No backup yet in {repo_id}. First sync in {SYNC_INTERVAL}s.")
                else:
                    raise
    except Exception as exc:
        log.warning("Restore failed: %s", exc)
        _write_status("error", f"Restore failed: {exc}")
        raise


def sync_once():
    if not HF_TOKEN:
        return

    try:
        api = _get_api()
        repo_id = _resolve_repo_id(api)
        _ensure_repo(api, repo_id)

        with tempfile.TemporaryDirectory() as tmp:
            archive = Path(tmp) / ARCHIVE_NAME
            _make_archive(archive)

            if not archive.exists() or archive.stat().st_size == 0:
                log.info("Nothing to backup — skipping upload.")
                _write_status("synced", "Nothing to backup — skipping upload.")
                return

            api.upload_file(
                path_or_fileobj=str(archive),
                path_in_repo=ARCHIVE_NAME,
                repo_id=repo_id,
                repo_type="dataset",
                token=HF_TOKEN,
            )
            size_kb = archive.stat().st_size // 1024
            log.info("State synced to %s (%d KB)", repo_id, size_kb)
            _write_status("synced", f"Synced to {repo_id} ({size_kb} KB)")
    except Exception as exc:
        log.warning("Sync failed: %s", exc)
        _write_status("error", f"Sync failed: {exc}")


def loop():
    log.info("Starting periodic sync (interval: %ds)", SYNC_INTERVAL)
    while True:
        time.sleep(SYNC_INTERVAL)
        try:
            sync_once()
        except Exception as exc:
            log.warning("Periodic sync error: %s", exc)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "help"
    if cmd == "restore":
        restore()
    elif cmd == "sync-once":
        sync_once()
    elif cmd == "loop":
        loop()
    else:
        print(__doc__)
        sys.exit(1)
