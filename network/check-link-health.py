#!/usr/bin/env python3
"""Report wired-link health: negotiated speed, kernel link drops, PHY downshifts,
and NIC error-counter deltas for each configured interface.

A wired link can flap or fall back to a lower speed while every service stays
up, because another route (for example wifi) carries the traffic. This probe
looks at the link itself so that state cannot go unnoticed.

Missing or unparsable evidence is reported as unknown (WARN), never OK.
Exit: 0 = OK, 1 = WARN (degraded or unknown), 2 = FAIL (flapping, link down, or
invalid configuration). `--signals` instead prints brokkr-platform-observation
signals for scripts/platform-fault-detector.mjs and exits 0 (2 on bad config).
"""

from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import time


PASS = 0
WARN = 1
FAIL = 2
PREFIX = {PASS: "OK", WARN: "WARN", FAIL: "FAIL"}
HOUR = 3600
DAY = 86400
COMMAND_TIMEOUT_SECS = 15
MAX_CONFIG_BYTES = 16384
MAX_LINKS = 8
MAX_THRESHOLD = 1_000_000
DEFAULT_THRESHOLDS = {
    "DROPS_1H_FAIL": 3,
    "DROPS_24H_WARN": 2,
    "DROPS_24H_FAIL": 24,
    "DOWNSHIFTS_24H_WARN": 1,
    "ERRORS_WARN": 10,
}
IFACE_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,14}$")  # IFNAMSIZ - 1
PHY_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,63}$")
POSITIVE = re.compile(r"^[1-9][0-9]{0,6}$")
JOURNAL_RECORD = re.compile(r"^([0-9]{1,12})(?:\.[0-9]{1,9})?\s+\S+\s+(.*)$")
BOOT_SEPARATOR = re.compile(r"^-- .* --$")
DOWNSHIFT = re.compile(r"Downshift occurred from negotiated speed (\S+) to actual speed ([^\s,]+)")
SECRET_ENV = re.compile(r"HEIMDALL|TOKEN|SECRET|PASSWORD|CREDENTIAL|KEY", re.IGNORECASE)
JOURNAL_ACCESS_HINTS = ("not seeing messages from other users and the system", "insufficient permissions")


class ConfigError(Exception):
    pass


def default_config_path() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "brokkr", "link-health.conf")


def load_config(path: str) -> tuple[list[dict[str, object]], dict[str, int]]:
    """Parse the protected config as data; it is never sourced."""
    if not os.path.isabs(path):
        raise ConfigError("path must be absolute")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        raise ConfigError("file is unavailable") from None
    except OSError as error:
        raise ConfigError(f"file cannot be opened safely ({error.strerror})") from None
    with os.fdopen(fd, "rb") as fh:
        info = os.fstat(fh.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise ConfigError("must be a regular non-symlink file")
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise ConfigError("must be owned by the current user with no group/other access")
        raw = fh.read(MAX_CONFIG_BYTES + 1)
    if len(raw) > MAX_CONFIG_BYTES:
        raise ConfigError("file is too large")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise ConfigError("file is not UTF-8") from None
    if re.search(r"[\x00-\x08\x0b-\x1f\x7f]", text):
        raise ConfigError("file contains control characters")

    links: list[dict[str, object]] = []
    thresholds = dict(DEFAULT_THRESHOLDS)
    seen: set[str] = set()
    for number, line in enumerate(text.split("\n"), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep:
            raise ConfigError(f"line {number} is not KEY=VALUE")
        if key == "LINK":
            parts = value.split(",")
            if len(parts) not in (2, 3) or not IFACE_NAME.match(parts[0]) or not POSITIVE.match(parts[1]):
                raise ConfigError(f"line {number}: LINK must be <iface>,<min-mbps>[,<phy>]")
            if len(parts) == 3 and not PHY_NAME.match(parts[2]):
                raise ConfigError(f"line {number}: invalid PHY name")
            if parts[0] in {link["iface"] for link in links}:
                raise ConfigError(f"line {number}: duplicate interface")
            links.append({"iface": parts[0], "min_mbps": int(parts[1]), "phy": parts[2] if len(parts) == 3 else None})
        elif key in DEFAULT_THRESHOLDS:
            if key in seen:
                raise ConfigError(f"line {number}: duplicate {key}")
            if not POSITIVE.match(value) or int(value) > MAX_THRESHOLD:
                raise ConfigError(f"line {number}: {key} must be a positive integer")
            thresholds[key] = int(value)
            seen.add(key)
        else:
            raise ConfigError(f"line {number}: unknown key")
    if not links:
        raise ConfigError("no LINK records")
    if len(links) > MAX_LINKS:
        raise ConfigError(f"more than {MAX_LINKS} LINK records")
    return links, thresholds


def run(argv: list[str]) -> subprocess.CompletedProcess[str] | None:
    # Children get no inherited secrets (the unit's EnvironmentFile carries a token).
    env = {k: v for k, v in os.environ.items() if not SECRET_ENV.search(k)}
    env["LC_ALL"] = "C"
    try:
        return subprocess.run(argv, check=False, capture_output=True, text=True,
                              timeout=COMMAND_TIMEOUT_SECS, env=env)
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        return None


def read_journal(now: int) -> tuple[list[tuple[int, str]] | None, str | None]:
    """Return kernel records from the last 24 h, or (None, reason) when unknown."""
    base = ["journalctl", "-q", "--no-pager", "-o", "short-unix"]
    # An unprivileged reader sees an empty kernel journal with exit 0. Require a
    # current-boot kernel record first so "no records" cannot mean "no access".
    proof = run(base + ["-k", "-b", "-n", "1"])
    if proof is None or proof.returncode != 0:
        return None, "journalctl failed"
    if any(hint in proof.stderr for hint in JOURNAL_ACCESS_HINTS) or not proof.stdout.strip():
        return None, "kernel journal unreadable"
    # Not -k: it implies -b and would hide drops from before a reboot in the window.
    result = run(base + ["--since", f"@{now - DAY}", "_TRANSPORT=kernel"])
    if result is None or result.returncode != 0:
        return None, "journalctl failed"
    if any(hint in result.stderr for hint in JOURNAL_ACCESS_HINTS):
        return None, "kernel journal unreadable"
    records = []
    for raw in result.stdout.splitlines():
        if not raw.strip() or raw[0].isspace() or BOOT_SEPARATOR.match(raw):
            continue  # blank, multi-line continuation, or boot separator
        match = JOURNAL_RECORD.match(raw)
        if match is None:
            return None, "unparsable journal record"
        records.append((int(match.group(1)), match.group(2)))
    return records, None


def names(*tokens: str | None) -> re.Pattern[str]:
    alternatives = "|".join(re.escape(token) for token in tokens if token)
    return re.compile(rf"(?<![A-Za-z0-9_.:-])(?:{alternatives})")


def journal_events(records: list[tuple[int, str]], now: int, link: dict[str, object]) -> dict[str, object]:
    iface = str(link["iface"])
    # r8169/phylib print "<iface>: Link is Down"; e1000e/igb print "<iface> NIC Link is Down".
    drop = re.compile(names(iface).pattern + r"(?::| NIC) Link is Down")
    # phylib logs downshifts under the PHY device name, not the interface name.
    downshift_owner = re.compile(names(iface, link["phy"]).pattern + r":")
    drops_1h = drops_24h = downshifts = 0
    last_downshift = None
    for stamp, message in records:
        if stamp < now - DAY:
            continue
        if drop.search(message):
            drops_24h += 1
            if stamp >= now - HOUR:
                drops_1h += 1
        shift = DOWNSHIFT.search(message)
        if shift and downshift_owner.search(message):
            downshifts += 1
            last_downshift = f"{shift.group(1)}->{shift.group(2)}"
    return {"drops_1h": drops_1h, "drops_24h": drops_24h, "downshifts": downshifts, "last_downshift": last_downshift}


def ethtool_fields(output: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    key = None
    for line in output.splitlines():
        match = re.match(r"^\s*([^:]+):\s*(.*)$", line)
        if match:
            key = match.group(1).strip()
            fields[key] = match.group(2).strip()
        elif key is not None and line.strip():
            fields[key] += " " + line.strip()  # continuation of a link-mode list
    return fields


def read_link(iface: str) -> dict[str, object]:
    result = run(["ethtool", iface])
    if result is None or result.returncode != 0:
        return {"error": "ethtool failed"}
    fields = ethtool_fields(result.stdout)
    detected = {"yes": True, "no": False}.get(fields.get("Link detected", ""))
    speed_match = re.fullmatch(r"([0-9]+)Mb/s", fields.get("Speed", ""))
    partner_speeds = [int(n) for n in re.findall(r"\b([0-9]+)base", fields.get("Link partner advertised link modes", ""))]
    return {
        "detected": detected,
        "speed": int(speed_match.group(1)) if speed_match else None,
        "partner_max": max(partner_speeds) if partner_speeds else None,
    }


def read_counters(iface: str) -> dict[str, str] | None:
    """tx_errors/rx_errors from ethtool -S, else the kernel's generic sysfs counters."""
    result = run(["ethtool", "-S", iface])
    if result is not None and result.returncode == 0:
        counters = dict(re.findall(r"^\s+([A-Za-z0-9_]+):\s+([0-9]+)\s*$", result.stdout, re.MULTILINE))
        if "tx_errors" in counters and "rx_errors" in counters:
            return counters
    # Not every driver names these in ethtool -S; every netdev exposes them in sysfs.
    sysfs = os.path.join(os.environ.get("BROKKR_SYSFS_NET") or "/sys/class/net", iface, "statistics")
    counters = {}
    for name in ("tx_errors", "rx_errors"):
        try:
            with open(os.path.join(sysfs, name), encoding="ascii") as fh:
                value = fh.read().strip()
        except (OSError, UnicodeError):
            return None
        if not re.fullmatch(r"[0-9]+", value):
            return None
        counters[name] = value
    return counters


def error_delta(iface: str, now: int, state_dir: str) -> tuple[str, int | None, str | None]:
    """Return (label, delta, unknown_reason) for tx_errors + rx_errors since the last run."""
    counters = read_counters(iface)
    if counters is None:
        return "unknown", None, "tx/rx error counters unavailable"
    current = {"epoch": now, "tx_errors": int(counters["tx_errors"]), "rx_errors": int(counters["rx_errors"])}

    path = os.path.join(state_dir, "link-health", f"{iface}.json")
    previous = None
    try:
        with open(path, encoding="utf-8") as fh:
            loaded = json.load(fh)
        if isinstance(loaded, dict) and all(isinstance(loaded.get(k), int) for k in current):
            previous = loaded
    except (OSError, ValueError):
        previous = None  # absent or corrupt baseline: start a new one

    label, delta = "baseline", None
    if (previous is not None and 0 < now - previous["epoch"] <= DAY
            and current["tx_errors"] >= previous["tx_errors"] and current["rx_errors"] >= previous["rx_errors"]):
        delta = (current["tx_errors"] - previous["tx_errors"]) + (current["rx_errors"] - previous["rx_errors"])
        label = f"+{delta}/{now - previous['epoch']}s"

    tmp = f"{path}.{os.getpid()}.tmp"
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(current, fh)
        os.replace(tmp, path)
    except OSError as error:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return label, delta, f"counter baseline not recorded ({error.strerror})"
    return label, delta, None


def assess(link: dict[str, object], thresholds: dict[str, int], journal: tuple, now: int, state_dir: str) -> dict[str, object]:
    iface = str(link["iface"])
    min_mbps = int(link["min_mbps"])
    records, journal_unknown = journal
    flapping: list[str] = []
    degraded: list[str] = []
    unknown: list[str] = []

    state = read_link(iface)
    if "error" in state:
        unknown.append(str(state["error"]))
        state = {"detected": None, "speed": None, "partner_max": None}
    if state["detected"] is False:
        flapping.append("link down")
    elif state["detected"] is None and not unknown:
        unknown.append("link state not reported")
    if state["detected"] is not False:
        if state["speed"] is None:
            if "ethtool failed" not in unknown:
                unknown.append("speed not reported")
        elif state["speed"] < min_mbps:
            degraded.append(f"speed {state['speed']}Mb/s < {min_mbps}Mb/s")

    events = None
    if records is None:
        unknown.append(str(journal_unknown))
    else:
        events = journal_events(records, now, link)
        if events["drops_1h"] >= thresholds["DROPS_1H_FAIL"]:
            flapping.append(f"{events['drops_1h']} drops in 1h")
        if events["drops_24h"] >= thresholds["DROPS_24H_FAIL"]:
            flapping.append(f"{events['drops_24h']} drops in 24h")
        elif events["drops_24h"] >= thresholds["DROPS_24H_WARN"]:
            degraded.append(f"{events['drops_24h']} drops in 24h")
        if events["downshifts"] >= thresholds["DOWNSHIFTS_24H_WARN"]:
            degraded.append(f"downshift {events['last_downshift']} x{events['downshifts']} in 24h")

    errors_label, delta, errors_unknown = error_delta(iface, now, state_dir)
    if errors_unknown:
        unknown.append(errors_unknown)
    if delta is not None and delta >= thresholds["ERRORS_WARN"]:
        degraded.append(f"{delta} new tx/rx errors")

    # Severity: drops or a down link fail; a slow, downshifted, or erroring link
    # warns; any missing evidence keeps the result at least WARN.
    status = FAIL if flapping else WARN if degraded or unknown else PASS
    reasons = flapping + degraded + [f"unknown: {reason}" for reason in unknown]

    def show(value: object, suffix: str = "") -> str:
        return "unknown" if value is None else f"{value}{suffix}"

    counts = events or {"drops_1h": None, "drops_24h": None, "downshifts": None}
    segment = " ".join([
        f"{iface} [{', '.join(reasons) or 'nominal'}]",
        f"speed={show(state['speed'], 'Mb/s')}",
        f"min={min_mbps}Mb/s",
        f"partner-max={show(state['partner_max'], 'Mb/s')}",
        f"drops1h={show(counts['drops_1h'])}",
        f"drops24h={show(counts['drops_24h'])}",
        f"downshifts24h={show(counts['downshifts'])}",
        f"errors={errors_label}",
    ])

    flapping_evidence_missing = records is None or state["detected"] is None
    degraded_evidence_missing = bool(unknown)
    provenance = f"ethtool+journalctl-k:{iface}"
    signals = [
        {"name": "network_link_flapping",
         "state": "fault" if flapping else "unknown" if flapping_evidence_missing else "ok",
         "provenance": provenance, "assertion": "; ".join(flapping) or segment},
        {"name": "network_link_degraded",
         "state": "fault" if degraded else "unknown" if degraded_evidence_missing else "ok",
         "provenance": provenance, "assertion": "; ".join(degraded) or segment},
    ]
    return {"status": status, "segment": segment, "signals": signals}


def observation_clock() -> int:
    raw = os.environ.get("BROKKR_NOW_EPOCH")
    if raw is None:
        return int(time.time())
    if not re.fullmatch(r"[0-9]{1,12}", raw):
        raise ConfigError("invalid BROKKR_NOW_EPOCH")
    return int(raw)


def main(argv: list[str]) -> int:
    if argv not in ([], ["--signals"]):
        print("usage: check-link-health.py [--signals]", file=sys.stderr)
        return 64
    signals_mode = argv == ["--signals"]
    try:
        links, thresholds = load_config(os.environ.get("BROKKR_LINK_HEALTH_CONFIG") or default_config_path())
        now = observation_clock()
    except ConfigError as error:
        message = f"link-health config invalid: {error}"
        print(f"FAIL: {message}", file=sys.stderr if signals_mode else sys.stdout)
        return FAIL

    state_dir = os.environ.get("BROKKR_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".local", "state", "brokkr")
    journal = read_journal(now)
    results = [assess(link, thresholds, journal, now, state_dir) for link in links]

    if signals_mode:
        json.dump([signal for result in results for signal in result["signals"]], sys.stdout)
        sys.stdout.write("\n")
        return 0
    worst = max(result["status"] for result in results)
    print(f"{PREFIX[worst]}: " + "; ".join(result["segment"] for result in results))
    return worst


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as error:  # report a crash as FAIL with its cause, never as a pass
        print(f"FAIL: link-health probe error: {type(error).__name__}: {error}")
        sys.exit(FAIL)
