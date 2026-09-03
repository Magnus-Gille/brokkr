#!/usr/bin/env python3
"""Read-only, bounded Time Machine destination evidence probe (brokkr#53)."""
import json
import os
import stat
import sys
import time


def emit(status, reason, observed_at, count=0, size_bytes=0, latest_epoch=None):
    data = {
        "status": status,
        "reason": reason,
        "observed_at": observed_at,
        "count": count,
        "size_bytes": size_bytes,
    }
    if latest_epoch is not None:
        data["latest_epoch"] = int(latest_epoch)
        data["age_seconds"] = max(0, observed_at - int(latest_epoch))
    print(json.dumps(data, separators=(",", ":")))
    return {"pass": 0, "warn": 1, "fail": 2}[status]


def integer(name, default, minimum, maximum=None):
    try:
        value = int(os.environ.get(name, default))
    except ValueError:
        raise ValueError(name)
    if value < minimum:
        raise ValueError(name)
    if maximum is not None and value > maximum:
        raise ValueError(name)
    return value


def valid_path(value):
    return (
        value.startswith("/")
        and value != "/"
        and not value.endswith("/")
        and "//" not in value
        and all(part not in (".", "..") for part in value.split("/"))
    )


def main():
    try:
        now = integer("BROKKR_TM_NOW_EPOCH", str(int(time.time())), 1)
        max_age = integer("BROKKR_TM_MAX_AGE_SECS", "93600", 1, 2678400)
        max_entries = integer("BROKKR_TM_PROBE_MAX_ENTRIES", "100000", 1)
        max_depth = integer("BROKKR_TM_PROBE_MAX_DEPTH", "3", 1)
        timeout = integer("BROKKR_TM_PROBE_TIMEOUT_SECS", "20", 1)
    except ValueError:
        return emit("warn", "invalid_configuration", int(time.time()))

    root = os.environ.get("BROKKR_TM_BANDS_DIR", "")
    if not valid_path(root):
        return emit("warn", "invalid_source", now)
    try:
        root_stat = os.lstat(root)
        if stat.S_ISLNK(root_stat.st_mode) or not stat.S_ISDIR(root_stat.st_mode):
            return emit("warn", "invalid_source", now)
    except (OSError, ValueError):
        return emit("warn", "source_unavailable", now)

    deadline = time.monotonic() + timeout
    pending = [(root, 0)]
    count = size_bytes = 0
    latest_epoch = None
    try:
        while pending:
            if time.monotonic() > deadline:
                return emit("warn", "scan_timeout", now, count, size_bytes, latest_epoch)
            directory, depth = pending.pop()
            with os.scandir(directory) as entries:
                for entry in entries:
                    if time.monotonic() > deadline:
                        return emit("warn", "scan_timeout", now, count, size_bytes, latest_epoch)
                    if entry.is_symlink():
                        return emit("warn", "symlink_detected", now, count, size_bytes, latest_epoch)
                    if entry.is_dir(follow_symlinks=False):
                        if depth < max_depth:
                            pending.append((entry.path, depth + 1))
                        continue
                    if not entry.is_file(follow_symlinks=False):
                        continue
                    info = entry.stat(follow_symlinks=False)
                    count += 1
                    if count > max_entries:
                        return emit("warn", "entry_limit", now, count, size_bytes, latest_epoch)
                    size_bytes += info.st_size
                    latest_epoch = max(latest_epoch or 0, int(info.st_mtime))
    except (OSError, ValueError):
        return emit("warn", "source_unreadable", now, count, size_bytes, latest_epoch)

    if count == 0:
        return emit("fail", "no_band_files", now)
    if latest_epoch is None or latest_epoch > now:
        return emit("warn", "invalid_timestamp", now, count, size_bytes, latest_epoch)
    if now - latest_epoch >= max_age:
        return emit("fail", "stale_band_files", now, count, size_bytes, latest_epoch)
    return emit("pass", "fresh_band_files", now, count, size_bytes, latest_epoch)


if __name__ == "__main__":
    sys.exit(main())
