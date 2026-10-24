#!/usr/bin/env python3
"""Report wired-link health: negotiated speed, kernel link drops, PHY downshifts,
and NIC error-counter deltas for each configured interface. The kernel's own
carrier-down counter cross-checks the journal, so drops journald never ingested
still count.

A wired link can flap or fall back to a lower speed while every service stays
up, because another route (for example wifi) carries the traffic. This probe
looks at the link itself so that state cannot go unnoticed.

Missing or unparsable evidence is reported as unknown (WARN), never OK.
Exit: 0 = OK, 1 = WARN (degraded or unknown), 2 = FAIL (flapping, link down, or
invalid configuration). `--signals` instead prints brokkr-platform-observation
signals for scripts/platform-fault-detector.mjs and exits 0 (2 on bad config).
`--check-config` only parses and validates the protected config (no NIC or
journal access) for deployment preflight: exit 0 when valid, 2 when not.
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
MAX_CARRIER_SAMPLES = 512  # 24 h of runs every 3 minutes
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


def ethtool_binary() -> str:
    """BROKKR_ETHTOOL pins an absolute path (a user manager's PATH may lack /usr/sbin)."""
    return os.environ.get("BROKKR_ETHTOOL") or "ethtool"


def run(argv: list[str]) -> subprocess.CompletedProcess[str] | None:
    # Children get no inherited secrets (the unit's EnvironmentFile carries a token).
    env = {k: v for k, v in os.environ.items() if not SECRET_ENV.search(k)}
    env["LC_ALL"] = "C"
    try:
        return subprocess.run(argv, check=False, capture_output=True, text=True,
                              timeout=COMMAND_TIMEOUT_SECS, env=env)
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        return None


def parse_records(output: str) -> list[tuple[int, str]] | None:
    records = []
    for raw in output.splitlines():
        if not raw.strip() or raw[0].isspace() or BOOT_SEPARATOR.match(raw):
            continue  # blank, multi-line continuation, or boot separator
        match = JOURNAL_RECORD.match(raw)
        if match is None:
            return None
        records.append((int(match.group(1)), match.group(2)))
    return records


FALSE_WORDS = {"no", "false", "0", "off"}
TRUE_WORDS = {"yes", "true", "1", "on"}


def kernel_ingestion_unknown() -> str | None:
    """Return a reason when journald's kernel-message collection is off or unverifiable.

    Coverage is proven from system-journal records of any transport, so it must
    not stand in for kernel evidence when journald does not read kernel messages.
    """
    result = run(["systemd-analyze", "cat-config", "systemd/journald.conf"])
    if result is None or result.returncode != 0:
        return "cannot verify that journald reads kernel messages"
    value = "yes"  # journald's default; later drop-ins override earlier lines
    section = None
    for line in result.stdout.splitlines():
        stripped = line.strip()
        if not stripped or stripped[0] in "#;":
            continue
        header = re.fullmatch(r"\[([^\]]+)\]", stripped)
        if header:
            section = header.group(1)
            continue
        match = re.fullmatch(r"ReadKMsg\s*=\s*(\S*)", stripped)
        if match and section == "Journal":
            value = match.group(1).lower()
            if value not in FALSE_WORDS | TRUE_WORDS:
                return f"journald ReadKMsg value {value!r} is not a boolean"
    if value in FALSE_WORDS:
        return "journald does not read kernel messages (ReadKMsg)"
    return None


def read_journal(now: int) -> tuple[list[tuple[int, str]] | None, str | None, int | None]:
    """Return (records from the last 24 h, unknown reason, history start).

    History start is None when the system journal reaches back before the
    window, so the counts are complete; otherwise it is the earliest kernel
    record seen, and any count over a window that starts earlier is only a
    lower bound.
    """
    base = ["journalctl", "-q", "--no-pager", "-o", "short-unix"]
    # An unprivileged reader sees an empty system journal with exit 0. Require a
    # system-journal record first so "no records" cannot mean "no access". Any
    # transport counts: a healthy kernel can stay silent for days.
    proof = run(base + ["--system", "-n", "1"])
    if proof is None or proof.returncode != 0:
        return None, "journalctl failed", None
    if any(hint in proof.stderr for hint in JOURNAL_ACCESS_HINTS) or not proof.stdout.strip():
        return None, "kernel journal unreadable", None
    ingestion = kernel_ingestion_unknown()
    if ingestion is not None:
        return None, ingestion, None
    # Not -k: it implies -b and would hide drops from before a reboot in the window.
    result = run(base + ["--since", f"@{now - DAY}", "_TRANSPORT=kernel"])
    if result is None or result.returncode != 0:
        return None, "journalctl failed", None
    if any(hint in result.stderr for hint in JOURNAL_ACCESS_HINTS):
        return None, "kernel journal unreadable", None
    records = parse_records(result.stdout)
    if records is None:
        return None, "unparsable journal record", None
    # A volatile or vacuumed journal can begin inside the window (for example after
    # a reboot). Any system-journal record from before the window proves the kernel
    # records in it are complete; requiring a *kernel* record there made quiet,
    # healthy hosts report partial coverage forever.
    before = run(base + ["--system", "--until", f"@{now - DAY}", "-n", "1"])
    if before is None or before.returncode != 0:
        return None, "journalctl failed", None
    earlier = parse_records(before.stdout)
    if earlier is None:
        return None, "unparsable journal record", None
    if earlier or any(stamp < now - DAY for stamp, _ in records):
        return records, None, None
    return records, None, min((stamp for stamp, _ in records), default=now)


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
    drop_stamps: list[int] = []
    last_downshift = None
    for stamp, message in records:
        if stamp < now - DAY or stamp > now:
            continue  # outside the window, or stamped after a clock correction
        if drop.search(message):
            drops_24h += 1
            if stamp >= now - HOUR:
                drops_1h += 1
            drop_stamps.append(stamp)
        shift = DOWNSHIFT.search(message)
        if shift and downshift_owner.search(message):
            downshifts += 1
            last_downshift = f"{shift.group(1)}->{shift.group(2)}"
    return {"drops_1h": drops_1h, "drops_24h": drops_24h, "drop_stamps": drop_stamps,
            "downshifts": downshifts, "last_downshift": last_downshift}


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
    result = run([ethtool_binary(), iface])
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


def sysfs_net() -> str:
    return os.environ.get("BROKKR_SYSFS_NET") or "/sys/class/net"


def read_counters(iface: str) -> dict[str, str] | None:
    """tx_errors/rx_errors from ethtool -S, else the kernel's generic sysfs counters."""
    result = run([ethtool_binary(), "-S", iface])
    if result is not None and result.returncode == 0:
        counters = dict(re.findall(r"^\s+([A-Za-z0-9_]+):\s+([0-9]+)\s*$", result.stdout, re.MULTILINE))
        if "tx_errors" in counters and "rx_errors" in counters:
            return counters
    # Not every driver names these in ethtool -S; every netdev exposes them in sysfs.
    sysfs = os.path.join(sysfs_net(), iface, "statistics")
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


def read_carrier_downs(iface: str) -> tuple[int | None, str | None]:
    """Return (carrier_down_count, unknown reason); (None, None) when the kernel lacks it."""
    try:
        with open(os.path.join(sysfs_net(), iface, "carrier_down_count"), encoding="ascii") as fh:
            value = fh.read().strip()
    except FileNotFoundError:
        return None, None  # before Linux 4.16: the cross-check is unavailable
    except (OSError, UnicodeError):
        return None, "carrier_down_count unreadable"
    if not re.fullmatch(r"[0-9]+", value):
        return None, "carrier_down_count unparsable"
    return int(value), None


def read_ifindex(iface: str) -> tuple[int | None, str | None]:
    """The interface index, which changes when the netdev is re-created (driver reload)."""
    try:
        with open(os.path.join(sysfs_net(), iface, "ifindex"), encoding="ascii") as fh:
            value = fh.read().strip()
    except (OSError, UnicodeError):
        return None, "interface ifindex unreadable"
    if not re.fullmatch(r"[1-9][0-9]*", value):
        return None, "interface ifindex unparsable"
    return int(value), None


BOOT_ID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def read_boot_id() -> str | None:
    """The kernel's per-boot UUID, or None where it cannot be read."""
    try:
        with open(os.environ.get("BROKKR_BOOT_ID_FILE") or "/proc/sys/kernel/random/boot_id", encoding="ascii") as fh:
            value = fh.read().strip()
    except (OSError, UnicodeError):
        return None
    return value if BOOT_ID.match(value) else None


def is_count(value: object) -> bool:
    return type(value) is int and value >= 0


def is_generation(value: object) -> bool:
    return (isinstance(value, dict) and set(value) == {"boot_id", "ifindex"} and is_count(value["ifindex"])
            and (value["boot_id"] is None or isinstance(value["boot_id"], str) and bool(BOOT_ID.match(value["boot_id"]))))


def counter_deltas(iface: str, now: int, state_dir: str) -> dict[str, object]:
    """Compare tx/rx error and carrier-down counters with earlier runs' baselines.

    The error delta is against the previous run. Carrier counts are kept as a
    rolling 24 h list of samples, so a carrier loss the journal missed stays
    visible for the whole window. A delta is None unless a valid earlier sample
    exists; every such case adds an unknown reason, except a kernel without
    carrier_down_count ("unavailable").
    """
    counters = read_counters(iface)
    carrier, carrier_reason = read_carrier_downs(iface)
    ifindex = None
    if carrier is not None:
        # Without the netdev's identity a count cannot be compared across a reload.
        ifindex, ifindex_reason = read_ifindex(iface)
        if ifindex is None:
            carrier, carrier_reason = None, ifindex_reason
    unknown: list[str] = []
    out: dict[str, object] = {
        "errors_label": "unknown", "errors": None,
        "carrier_label": "unavailable" if carrier is None and carrier_reason is None else "unknown",
        "carrier_windows": None, "unknown": unknown,
    }
    if counters is None:
        unknown.append("tx/rx error counters unavailable")
    if carrier_reason:
        unknown.append(carrier_reason)

    # Without a valid earlier sample there is no counter evidence yet: record a new
    # baseline but report the checks unknown until a later run can compare.
    path = os.path.join(state_dir, "link-health", f"{iface}.json")
    loaded: dict[str, object] = {}
    baseline = None
    try:
        with open(path, encoding="utf-8") as fh:
            loaded = json.load(fh)
        if not isinstance(loaded, dict):
            loaded, baseline = {}, "counter baseline unreadable"
    except FileNotFoundError:
        baseline = "counter baseline recorded (first run)"
    except (OSError, ValueError):
        baseline = "counter baseline unreadable"
    if baseline and (counters is not None or carrier is not None):
        unknown.append(baseline)

    previous = None
    if baseline is None:
        if all(is_count(loaded.get(k)) for k in ("epoch", "tx_errors", "rx_errors")):
            previous = loaded
        elif counters is not None:
            unknown.append("counter baseline unreadable" if any(k in loaded for k in ("epoch", "tx_errors", "rx_errors"))
                           else "error baseline recorded (previous run had no error counters)")
    if previous is not None and not 0 < now - previous["epoch"] <= DAY:
        previous = None
        if counters is not None:
            unknown.append("counter baseline stale")
    if counters is not None:
        out["errors_label"] = "baseline"
        if previous is not None:
            if int(counters["tx_errors"]) < previous["tx_errors"] or int(counters["rx_errors"]) < previous["rx_errors"]:
                unknown.append("error counters reset (reboot or driver reload)")
            else:
                delta = (int(counters["tx_errors"]) - previous["tx_errors"]) + (int(counters["rx_errors"]) - previous["rx_errors"])
                out["errors"], out["errors_label"] = delta, f"+{delta}/{now - previous['epoch']}s"

    stored = loaded.get("carrier_samples")
    stored_generation = loaded.get("carrier_generation")
    samples: list[list[int]] = []
    if (isinstance(stored, list) and all(isinstance(x, list) and len(x) == 2 and is_count(x[0]) and is_count(x[1]) for x in stored)
            and is_generation(stored_generation)):
        samples = sorted((x for x in stored if now - DAY <= x[0] < now), key=lambda x: x[0])
    elif carrier is not None and baseline is None:
        unknown.append("carrier baseline unreadable" if stored is not None
                       else "carrier baseline recorded (previous run had no carrier count)")
    # A reboot, driver reload or re-created interface restarts the count, and
    # unlogged drops (or boot-time carrier events that log nothing) can bring it
    # back to or above the old value. Only a changed generation shows that.
    generation = {"boot_id": read_boot_id(), "ifindex": ifindex}
    reset = None
    if carrier is not None and samples and stored_generation != generation:
        reset, samples = "carrier counter generation changed (reboot, driver reload or re-created interface)", []
    if carrier is not None:
        out["carrier_label"] = "baseline"
        if reset:
            unknown.append(reset)
        elif samples and samples[-1][1] > carrier:
            unknown.append("carrier counter reset (reboot or driver reload)")
        elif samples:
            out["carrier_label"] = f"+{carrier - samples[-1][1]}/{now - samples[-1][0]}s"
        elif isinstance(stored, list):
            unknown.append("carrier baseline stale")
        # Older samples at or below the current count still give lower bounds:
        # every loss counted since the restart came after them.
        samples = [x for x in samples if x[1] <= carrier]
        if samples:
            out["carrier_windows"] = [(epoch, carrier - before) for epoch, before in samples]
        samples = (samples + [[now, carrier]])[-MAX_CARRIER_SAMPLES:]

    # Nothing new to record: keep the old baseline so the next run compares over
    # the longer interval instead of losing it.
    if counters is None and carrier is None:
        return out
    current: dict[str, object] = {k: loaded[k] for k in ("epoch", "tx_errors", "rx_errors") if previous is not None and counters is None}
    if counters is not None:
        current.update({"epoch": now, "tx_errors": int(counters["tx_errors"]), "rx_errors": int(counters["rx_errors"])})
    if samples:
        current["carrier_samples"] = samples
        current["carrier_generation"] = generation if carrier is not None else stored_generation
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
        unknown.append(f"counter baseline not recorded ({error.strerror})")
    return out


def assess(link: dict[str, object], thresholds: dict[str, int], journal: tuple, now: int, state_dir: str) -> dict[str, object]:
    iface = str(link["iface"])
    min_mbps = int(link["min_mbps"])
    records, journal_unknown, history_start = journal
    partial_24h = history_start is not None and history_start > now - DAY
    partial_1h = history_start is not None and history_start > now - HOUR
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

    counter = counter_deltas(iface, now, state_dir)
    windows = counter["carrier_windows"]
    events = None
    if records is None:
        unknown.append(str(journal_unknown))
    else:
        if partial_24h:
            # Partial counts are lower bounds: they can still cross a threshold.
            unknown.append(f"kernel journal covers only {now - history_start}s of 24h")
        events = journal_events(records, now, link)
    drops_1h = events["drops_1h"] if events else None
    drops_24h = events["drops_24h"] if events else None

    # The kernel counts every carrier loss itself, whether or not journald ingested
    # (or the driver logged) a "Link is Down" line. More carrier losses since an
    # earlier sample than logged drops since then prove the journal incomplete; the
    # excess is a lower bound on the missing drops and can cross the thresholds on
    # its own. Each sample within 24 h is compared, so a missed drop stays counted
    # for the whole window and a record that reaches the journal late reconciles.
    if windows is not None:
        stamps = events["drop_stamps"] if events else []
        worst = None
        excess_1h = excess_24h = 0
        for start, carrier_downs in windows:
            # Whole-second stamps: a record in the sample's own second counts as
            # logged, so the boundary can only hide a mismatch, never invent one.
            logged = sum(1 for stamp in stamps if stamp >= start)
            excess = carrier_downs - logged
            if excess > excess_24h:
                excess_24h, worst = excess, (carrier_downs, now - start, logged)
            if now - start <= HOUR:
                excess_1h = max(excess_1h, excess)
        if worst is not None:
            if events is not None:
                unknown.append(f"carrier went down {worst[0]}x in {worst[1]}s but the kernel journal shows {worst[2]}")
            partial_1h = partial_24h = True
            drops_24h = (drops_24h or 0) + excess_24h
            if excess_1h or drops_1h is not None:
                drops_1h = (drops_1h or 0) + excess_1h

    if drops_1h is not None and drops_1h >= thresholds["DROPS_1H_FAIL"]:
        flapping.append(f"{drops_1h} drops in 1h")
    if drops_24h is not None:
        if drops_24h >= thresholds["DROPS_24H_FAIL"]:
            flapping.append(f"{drops_24h} drops in 24h")
        elif drops_24h >= thresholds["DROPS_24H_WARN"]:
            degraded.append(f"{drops_24h} drops in 24h")
    if events and events["downshifts"] >= thresholds["DOWNSHIFTS_24H_WARN"]:
        degraded.append(f"downshift {events['last_downshift']} x{events['downshifts']} in 24h")

    unknown.extend(counter["unknown"])
    if counter["errors"] is not None and counter["errors"] >= thresholds["ERRORS_WARN"]:
        degraded.append(f"{counter['errors']} new tx/rx errors")

    # Severity: drops or a down link fail; a slow, downshifted, or erroring link
    # warns; any missing evidence keeps the result at least WARN.
    status = FAIL if flapping else WARN if degraded or unknown else PASS
    reasons = flapping + degraded + [f"unknown: {reason}" for reason in unknown]

    def show(value: object, suffix: str = "") -> str:
        return "unknown" if value is None else f"{value}{suffix}"

    counts = {"drops_1h": drops_1h, "drops_24h": drops_24h, "downshifts": events["downshifts"] if events else None}

    def count(key: str, partial: bool) -> str:
        value = counts[key]
        return "=unknown" if value is None else f">={value}" if partial else f"={value}"

    segment = " ".join([
        f"{iface} [{', '.join(reasons) or 'nominal'}]",
        f"speed={show(state['speed'], 'Mb/s')}",
        f"min={min_mbps}Mb/s",
        f"partner-max={show(state['partner_max'], 'Mb/s')}",
        f"drops1h{count('drops_1h', partial_1h)}",
        f"drops24h{count('drops_24h', partial_24h)}",
        f"downshifts24h{count('downshifts', partial_24h)}",
        f"errors={counter['errors_label']}",
        f"carrier-down={counter['carrier_label']}",
    ])

    carrier_missing = counter["carrier_label"] in ("unknown", "baseline")
    flapping_evidence_missing = records is None or partial_24h or carrier_missing or state["detected"] is None
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
    if argv not in ([], ["--signals"], ["--check-config"]):
        print("usage: check-link-health.py [--signals | --check-config]", file=sys.stderr)
        return 64
    if argv == ["--check-config"]:
        try:
            links, _thresholds = load_config(os.environ.get("BROKKR_LINK_HEALTH_CONFIG") or default_config_path())
        except ConfigError as error:
            print(f"FAIL: link-health config invalid: {error}")
            return FAIL
        print(f"OK: link-health config valid ({len(links)} link{'s' if len(links) != 1 else ''})")
        return PASS
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
