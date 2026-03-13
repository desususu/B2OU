"""
Command-line interface for b2ou.

Subcommands
-----------
export     Export Bear notes to Markdown / TextBundle files.
status     Show export state without modifying anything.
clean      Remove all exported files and reset incremental state.

Usage examples
--------------
  python -m b2ou export --out ~/Notes
  python -m b2ou export --out ~/Notes --format tb --tag-folders
  python -m b2ou export --out ~/Notes --watch
  python -m b2ou status --out ~/Notes
  python -m b2ou clean --out ~/Notes
"""

from __future__ import annotations

import argparse
import datetime
import json
import logging
import os
import signal
import sys
import time
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

def setup_logging(verbose: bool = False) -> None:
    """Configure root logging to stderr."""
    root = logging.getLogger()
    root.setLevel(logging.DEBUG if verbose else logging.INFO)

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s", datefmt="%Y-%m-%d %H:%M:%S"
    )
    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    root.addHandler(sh)


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------

def _write_status(status_file: Optional[Path], state: str, *,
                   note_count: int = 0, error: Optional[str] = None,
                   export_path: str = "") -> None:
    """Write a JSON status file for the menu-bar app to read."""
    if status_file is None:
        return
    data = {
        "state": state,
        "note_count": note_count,
        "last_update": datetime.datetime.now().isoformat(timespec="seconds"),
        "error": error,
        "export_path": export_path,
    }
    try:
        tmp = status_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(data))
        tmp.replace(status_file)
    except OSError:
        pass


def _run_export(cfg, log) -> int:
    """Run a single incremental export cycle. Returns note count."""
    from b2ou.export import (
        _write_manifest,
        cleanup_orphan_root_images,
        cleanup_stale_notes,
        export_notes,
        maintenance_due,
        purge_old_trash,
        touch_maintenance,
        write_timestamps,
    )

    total_count = 0
    total_changed = 0
    paths: list[str] = []

    for sub in cfg.split_export_configs():
        sub.export_path.mkdir(parents=True, exist_ok=True)
        note_count, expected, changed = export_notes(sub)
        if changed < 0:
            log.info("Export already running for %s — skipping.",
                     sub.export_path)
            continue
        write_timestamps(sub)

        # Skip expensive cleanup walks when nothing actually changed
        if changed > 0:
            # Run cleanup BEFORE updating the manifest so it can still
            # see old filenames (e.g. from a renamed note) and remove them.
            removed = cleanup_stale_notes(sub.export_path, expected, sub.on_delete)
            if removed:
                log.info("Cleaned %d stale files from export folder.", removed)

            if maintenance_due(sub.export_path):
                if sub.export_image_repository:
                    orphans = cleanup_orphan_root_images(sub)
                    if orphans:
                        log.info("Cleaned %d orphan root images.", orphans)

                purged = purge_old_trash(sub.export_path)
                if purged:
                    log.info("Purged %d old trash folders.", purged)

                touch_maintenance(sub.export_path)

        # Update manifest after cleanup so that the old manifest was
        # available during cleanup to identify previously-exported files.
        if expected:
            _write_manifest(sub.export_path, expected)

        total_count = max(total_count, note_count)
        total_changed += changed
        paths.append(str(sub.export_path))

    dest = ", ".join(paths)
    log.info("%d notes exported (%d changed) to: %s", total_count, total_changed, dest)
    return total_count


def _build_config_from_args(args: argparse.Namespace):
    """Build an ExportConfig from CLI arguments, with optional --profile."""
    from b2ou.config import ExportConfig

    # If --profile is given, load from TOML and apply CLI overrides
    if getattr(args, "profile", None):
        from b2ou.profile import load_profile
        cfg = load_profile(args.profile, getattr(args, "config", None))
        # Apply CLI overrides (only if explicitly set)
        if args.out:
            cfg.export_path = Path(args.out)
        if getattr(args, "out_tb", None):
            cfg.export_path_tb = Path(args.out_tb)
        if args.images:
            cfg.assets_path = Path(args.images)
        if args.force:
            pass  # handled in caller
        if getattr(args, "format", None):
            cfg.export_format = args.format
        if cfg.export_format == "both":
            if not cfg.export_path_tb:
                raise SystemExit(
                    "Error: --out-tb is required when --format both "
                    "(TextBundle output folder)"
                )
            if cfg.export_path_tb.resolve() == cfg.export_path.resolve():
                raise SystemExit(
                    "Error: Markdown and TextBundle output folders must be different."
                )
        return cfg

    # If --all is given, load all profiles
    if getattr(args, "all_profiles", False):
        from b2ou.profile import load_profiles
        profiles = load_profiles(getattr(args, "config", None))
        if not profiles:
            raise SystemExit("No profiles found in b2ou.toml")
        return profiles

    # Standard CLI-only config
    if not args.out:
        raise SystemExit("Error: --out is required (or use --profile)")
    assets = Path(args.images) if args.images else None
    cfg = ExportConfig(
        export_path=Path(args.out),
        export_path_tb=Path(args.out_tb) if args.out_tb else None,
        assets_path=assets,
        export_format=args.format,
        exclude_tags=args.exclude_tags,
        hide_tags=args.hide_tags,
        make_tag_folders=args.tag_folders,
        yaml_front_matter=args.yaml_front_matter,
        naming=args.naming,
        on_delete=args.on_delete,
    )
    if cfg.export_format == "both":
        if not cfg.export_path_tb:
            raise SystemExit(
                "Error: --out-tb is required when --format both "
                "(TextBundle output folder)"
            )
        if cfg.export_path_tb.resolve() == cfg.export_path.resolve():
            raise SystemExit(
                "Error: Markdown and TextBundle output folders must be different."
            )
    return cfg


def cmd_export(args: argparse.Namespace) -> int:
    """Export Bear notes to disk."""
    setup_logging(args.verbose)
    log = logging.getLogger(__name__)

    result = _build_config_from_args(args)

    # --all: run all profiles sequentially
    if isinstance(result, dict):
        for name, cfg in result.items():
            log.info("Running profile: %s", name)
            from b2ou.export import check_db_modified
            if not args.force and not check_db_modified(cfg):
                log.info("  Skipped (unchanged).")
                continue
            _run_export(cfg, log)
        return 0

    cfg = result

    status_file = Path(args.status_file) if args.status_file else None

    if args.watch:
        return _watch_loop(cfg, log, debounce=args.debounce,
                           status_file=status_file)

    from b2ou.export import check_db_modified

    if not args.force and not check_db_modified(cfg):
        log.info("No notes needed export (Bear database unchanged).")
        return 0

    _run_export(cfg, log)
    return 0


def _watch_loop(cfg, log, debounce: float = 3.0,
                status_file: Optional[Path] = None) -> int:
    """Re-export whenever Bear's database content changes.

    Uses content-level change detection (``bear_db_signature``) rather
    than file mtime to avoid redundant exports from WAL checkpoints or
    iCloud metadata writes that don't change actual note content.

    Enforces a minimum interval between exports to prevent rapid-fire
    cycles when the database is being edited continuously.
    """
    from b2ou.db import bear_db_signature, db_is_quiet

    MIN_INTERVAL = 10.0  # seconds between exports
    export_path_str = str(cfg.export_path)

    log.info("Watching Bear database for changes (debounce=%.1fs)...", debounce)
    log.info("Press Ctrl+C to stop.")

    _write_status(status_file, "watching", export_path=export_path_str)

    shutdown = False

    def _handle_signal(signum, frame):
        nonlocal shutdown
        shutdown = True

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    last_signature = (0.0, -1)
    last_export_time = 0.0
    consecutive_failures = 0
    note_count = 0
    idle_sleep = 2.0
    idle_max = 30.0

    while not shutdown:
        # Content-level change detection: cheap read-only SQL query
        sig = bear_db_signature(cfg.bear_db)
        if sig == last_signature or sig[1] < 0:
            time.sleep(idle_sleep)
            idle_sleep = min(idle_max, idle_sleep * 1.5)
            continue
        idle_sleep = 2.0

        # Enforce minimum interval between exports (with backoff on failures)
        interval = MIN_INTERVAL * (2 ** min(consecutive_failures, 4))
        elapsed = time.time() - last_export_time
        if last_export_time > 0 and elapsed < interval:
            time.sleep(min(2.0, interval - elapsed))
            continue

        # Wait for Bear to finish writing (DB + WAL + SHM quiet)
        if last_signature[1] >= 0:
            log.info("Bear database changed, waiting for writes to settle...")
            waited = 0.0
            while not shutdown and waited < debounce * 3:
                if db_is_quiet(cfg.bear_db, debounce):
                    break
                time.sleep(1.0)
                waited += 1.0

        _write_status(status_file, "exporting",
                      note_count=note_count, export_path=export_path_str)

        try:
            note_count = _run_export(cfg, log)
            last_export_time = time.time()
            consecutive_failures = 0
            _write_status(status_file, "idle",
                          note_count=note_count, export_path=export_path_str)
        except Exception as exc:
            consecutive_failures += 1
            backoff = MIN_INTERVAL * (2 ** min(consecutive_failures, 4))
            log.error("Export failed (%d consecutive): %s — retry in %.0fs",
                      consecutive_failures, exc, backoff)
            _write_status(status_file, "error",
                          note_count=note_count, error=str(exc),
                          export_path=export_path_str)

        # Re-read signature after export to get the definitive state
        last_signature = bear_db_signature(cfg.bear_db)
        time.sleep(2.0)

    _write_status(status_file, "stopped",
                  note_count=note_count, export_path=export_path_str)
    log.info("Watch mode stopped.")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Show export state without modifying anything."""
    setup_logging(args.verbose)

    from b2ou.config import ExportConfig
    from b2ou.db import bear_db_signature, core_data_to_unix

    cfg = ExportConfig(export_path=Path(args.out))
    export_path = cfg.export_path

    # Bear database info
    max_mod, note_count = bear_db_signature(cfg.bear_db)
    if note_count < 0:
        print(f"Bear database:     not found at {cfg.bear_db}")
        return 1

    mod_str = datetime.datetime.fromtimestamp(max_mod).strftime("%Y-%m-%d %H:%M:%S")
    print(f"Bear database:     {note_count:,} active notes (last modified: {mod_str})")

    # Export folder info
    if not export_path.is_dir():
        print(f"Export folder:     not found at {export_path}")
        return 0

    file_count = 0
    for _, _, files in os.walk(export_path):
        for f in files:
            if f.endswith((".md", ".txt", ".markdown", ".textbundle")):
                file_count += 1

    # Also count .textbundle directories
    bundle_count = 0
    for _, dirs, _ in os.walk(export_path):
        for d in dirs:
            if d.endswith(".textbundle"):
                bundle_count += 1

    total = file_count + bundle_count
    print(f"Export folder:     {total:,} files in {export_path}")

    # Pending changes
    ts_file = cfg.export_ts_file
    if ts_file.exists():
        try:
            ts_mtime = ts_file.stat().st_mtime
            db_mtime = cfg.bear_db.stat().st_mtime
            if db_mtime > ts_mtime:
                print("Pending changes:   database modified since last export")
            else:
                print("Pending changes:   none (up to date)")
        except OSError:
            print("Pending changes:   unknown")
    else:
        print("Pending changes:   never exported")

    return 0


def cmd_clean(args: argparse.Namespace) -> int:
    """Remove all exported files and reset incremental state."""
    import shutil

    setup_logging(args.verbose)
    log = logging.getLogger(__name__)

    export_path = Path(args.out)
    if not export_path.is_dir():
        log.error("Export folder does not exist: %s", export_path)
        return 1

    # Confirmation prompt
    if not args.yes:
        print(f"This will remove all exported notes from: {export_path}")
        if args.keep_images:
            print("(BearImages folder will be kept)")
        answer = input("Continue? [y/N] ").strip().lower()
        if answer not in ("y", "yes"):
            print("Aborted.")
            return 0

    removed = 0

    # Remove note files (.md, .txt, .markdown)
    for root, dirs, files in os.walk(export_path, topdown=True):
        root_path = Path(root)

        # Skip special directories
        skip = {".b2ou-trash", ".obsidian", "BearImages"}
        dirs[:] = [d for d in dirs
                   if d not in skip
                   and not d.startswith(".Ulysses")]

        # Remove .textbundle directories
        for d in list(dirs):
            if d.endswith(".textbundle"):
                bundle = root_path / d
                shutil.rmtree(bundle, ignore_errors=True)
                removed += 1
                dirs.remove(d)

        for fname in files:
            fpath = root_path / fname
            if fname.endswith((".md", ".txt", ".markdown")):
                fpath.unlink(missing_ok=True)
                removed += 1

    # Remove BearImages unless --keep-images
    if not args.keep_images:
        images_path = export_path / "BearImages"
        if images_path.is_dir():
            shutil.rmtree(images_path, ignore_errors=True)
            log.info("Removed BearImages folder.")

    # Remove sentinel / state files
    for name in (".export-time.log", ".b2ou-manifest"):
        p = export_path / name
        if p.exists():
            p.unlink(missing_ok=True)

    # Remove .b2ou-trash
    trash = export_path / ".b2ou-trash"
    if trash.is_dir():
        shutil.rmtree(trash, ignore_errors=True)
        log.info("Removed .b2ou-trash folder.")

    # Clean up empty subdirectories
    for root, dirs, files in os.walk(export_path, topdown=False):
        rp = Path(root)
        if rp != export_path:
            try:
                if not list(rp.iterdir()):
                    rp.rmdir()
            except OSError:
                pass

    log.info("Cleaned %d exported files from %s", removed, export_path)
    return 0


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="b2ou",
        description="Bear to Obsidian / Ulysses export tool",
    )
    parser.add_argument(
        "--version", action="version",
        version=f"%(prog)s {_version()}"
    )
    sub = parser.add_subparsers(dest="command", metavar="COMMAND")

    # ── export ───────────────────────────────────────────────────────────
    p_export = sub.add_parser("export", help="Export Bear notes to disk")
    p_export.add_argument("--out", default=None,
                          help="Destination folder for exported notes")
    p_export.add_argument("--profile", default=None, metavar="NAME",
                          help="Use settings from a b2ou.toml profile")
    p_export.add_argument("--all", action="store_true", dest="all_profiles",
                          help="Run all profiles from b2ou.toml")
    p_export.add_argument("--config", default=None, metavar="PATH",
                          help="Path to b2ou.toml (default: auto-discover)")
    p_export.add_argument("--images", default=None,
                          help="Override path for the BearImages asset folder")
    p_export.add_argument("--format", choices=["md", "tb", "both"], default="md",
                          help="Export format: md (Markdown), tb (TextBundle), or both")
    p_export.add_argument("--out-tb", default=None,
                          help="TextBundle output folder (required with --format both)")
    p_export.add_argument("--exclude-tag", action="append", dest="exclude_tags",
                          default=[], metavar="TAG",
                          help="Skip notes with this Bear tag (repeatable)")
    p_export.add_argument("--hide-tags", action="store_true",
                          help="Strip #tags from exported Markdown")
    p_export.add_argument("--tag-folders", action="store_true",
                          help="Organise notes into subdirectories by tag")
    p_export.add_argument("--yaml-front-matter", action="store_true",
                          help="Add YAML front matter with title, dates, tags, bear_id")
    p_export.add_argument("--naming",
                          choices=["title", "slug", "date-title", "id"],
                          default="title",
                          help="Filename strategy (default: title)")
    p_export.add_argument("--on-delete",
                          choices=["trash", "remove", "keep"],
                          default="trash",
                          help="How to handle stale files (default: trash)")
    p_export.add_argument("--force", action="store_true",
                          help="Re-export all notes, ignoring incremental cache")
    p_export.add_argument("--watch", action="store_true",
                          help="Re-export on Bear database changes")
    p_export.add_argument("--debounce", type=float, default=3.0,
                          metavar="SECONDS",
                          help="With --watch: seconds to wait after DB change (default: 3)")
    p_export.add_argument("--status-file", default=None, metavar="PATH",
                          help="Write JSON status to this file (for GUI integration)")
    p_export.add_argument("-v", "--verbose", action="store_true")
    p_export.set_defaults(func=cmd_export)

    # ── status ───────────────────────────────────────────────────────────
    p_status = sub.add_parser("status",
                              help="Show export state without modifying anything")
    p_status.add_argument("--out", required=True,
                          help="Export folder to inspect")
    p_status.add_argument("-v", "--verbose", action="store_true")
    p_status.set_defaults(func=cmd_status)

    # ── clean ────────────────────────────────────────────────────────────
    p_clean = sub.add_parser("clean",
                             help="Remove exported files and reset state")
    p_clean.add_argument("--out", required=True,
                         help="Export folder to clean")
    p_clean.add_argument("--keep-images", action="store_true",
                         help="Keep the BearImages folder, only remove note files")
    p_clean.add_argument("--yes", "-y", action="store_true",
                         help="Skip confirmation prompt")
    p_clean.add_argument("-v", "--verbose", action="store_true")
    p_clean.set_defaults(func=cmd_clean)

    args = parser.parse_args(argv)
    if not hasattr(args, "func"):
        parser.print_help()
        return 0

    return args.func(args)


def _version() -> str:
    try:
        from b2ou import __version__
        return __version__
    except ImportError:
        return "unknown"


if __name__ == "__main__":
    sys.exit(main())
