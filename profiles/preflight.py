#!/usr/bin/env python3
"""Fail-closed, read-only availability checks for Brokkr location profiles.

This script deliberately validates substrate facts only.  It never configures a
network, mounts storage, writes probe files, copies data, or invokes
application-specific tooling.  Diagnostics name schema fields but never echo
owner-supplied values or filesystem paths.
"""
import argparse
import json
import math
import os
import re
import stat
import subprocess
import sys

MAX_PROFILE_BYTES = 1_000_000
DEFAULT_COMMAND_TIMEOUT = 10.0
SAFE_KEY = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
DNS_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}")
FILESYSTEM_NAME = re.compile(r"[a-z0-9]{1,32}")
ABSOLUTE_PATH = re.compile(r"/[^\x00\n]{0,1023}")
PRINTABLE_SSID = re.compile(r"[^\x00-\x1f\x7f]{1,32}")
DEVICE_NAME = re.compile(r"[A-Za-z0-9._-]{1,32}")

COMMAND_TIMEOUT = DEFAULT_COMMAND_TIMEOUT


class PreflightError(Exception):
    """A safe, non-sensitive reason a preflight cannot proceed."""


def fail(message):
    raise PreflightError(message)


def schema_fail(label, path, problem):
    where = ".".join(path) if path else "document"
    fail(f"{label} {where} {problem}")


def check_schema_version(value, label, path):
    if isinstance(value, bool) or value != 1:
        fail(f"{label} declares an unsupported schema version")


def check_bool(value, label, path):
    if not isinstance(value, bool):
        schema_fail(label, path, "must be true or false")


def check_int(minimum, maximum):
    def check(value, label, path):
        if isinstance(value, bool) or not isinstance(value, int):
            schema_fail(label, path, "must be an integer")
        if not minimum <= value <= maximum:
            schema_fail(label, path, "is out of range")
    return check


def check_number(maximum):
    def check(value, label, path):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            schema_fail(label, path, "must be a number")
        if not math.isfinite(value) or not 0 < value <= maximum:
            schema_fail(label, path, "is out of range")
    return check


def check_string(pattern, problem):
    def check(value, label, path):
        if not isinstance(value, str) or not pattern.fullmatch(value):
            schema_fail(label, path, problem)
    return check


def check_object(fields):
    def check(value, label, path):
        if not isinstance(value, dict):
            schema_fail(label, path, "must be an object")
        for key in value:
            if key not in fields:
                schema_fail(label, path, "contains an unsupported field")
        for key, checker in fields.items():
            if key not in value:
                schema_fail(label, path + [key], "is missing")
            checker(value[key], label, path + [key])
    return check


def check_keyed_map(checker):
    def check(value, label, path):
        if not isinstance(value, dict) or not value:
            schema_fail(label, path, "must be a non-empty object")
        for key, item in value.items():
            if not isinstance(key, str) or not SAFE_KEY.fullmatch(key):
                schema_fail(label, path, "contains an invalid key")
            checker(item, label, path + [key])
    return check


def check_array(checker):
    def check(value, label, path):
        if not isinstance(value, list):
            schema_fail(label, path, "must be an array")
        for index, item in enumerate(value):
            checker(item, label, path + [str(index)])
    return check


PERCENT = check_int(1, 100)
THROUGHPUT_MBPS = check_number(100_000.0)
SAFE_NAME = check_string(SAFE_KEY, "must be a lowercase identifier")
OWNER_PATH = check_string(ABSOLUTE_PATH, "must be an absolute path")

PROFILE_SCHEMA = check_object({
    "schema_version": check_schema_version,
    "locations": check_keyed_map(check_object({
        "tailnet": check_object({"required": check_bool}),
        "network": check_object({
            "wifi": check_object({
                "required": check_bool,
                "min_signal_percent": PERCENT,
                "min_throughput_mbps": THROUGHPUT_MBPS,
            }),
            "ethernet": check_object({"min_throughput_mbps": THROUGHPUT_MBPS}),
        }),
        "storage": check_keyed_map(check_object({
            "filesystem": check_string(FILESYSTEM_NAME, "must be a filesystem name"),
            "max_used_percent": PERCENT,
            "requires_write": check_bool,
        })),
        "backup_roles": check_array(check_object({
            "logical_storage_id": SAFE_NAME,
            "producer": SAFE_NAME,
            "consumer": SAFE_NAME,
            "bytes": check_number(1e15),
            "window_minutes": check_number(10_080.0),
        })),
    })),
})

OVERLAY_SCHEMA = check_object({
    "schema_version": check_schema_version,
    "location": SAFE_NAME,
    "tailnet_identity": check_string(DNS_NAME, "must be a DNS name"),
    "wifi": check_object({
        "ssid": check_string(PRINTABLE_SSID, "must be a printable SSID"),
        "credentials_file": OWNER_PATH,
    }),
    "storage": check_keyed_map(check_object({"mount": OWNER_PATH})),
})


def load_json(path, label, private=False):
    try:
        info = os.lstat(path)
    except OSError:
        fail(f"{label} is unavailable")
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail(f"{label} must be a regular file")
    if info.st_size > MAX_PROFILE_BYTES:
        fail(f"{label} is invalid")
    if private:
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            fail(f"{label} must be owned by the invoking user and mode 600")
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        fail(f"{label} is invalid")
    return value


def command(*args):
    env = dict(os.environ, LC_ALL="C", LANG="C")
    try:
        return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, timeout=COMMAND_TIMEOUT,
                              env=env).stdout
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return None


def split_terse(line):
    """Split one `nmcli -t` line on unescaped colons, unescaping \\ and \\:."""
    fields, current, escaped = [], [], False
    for char in line:
        if escaped:
            current.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append("".join(current))
            current = []
        else:
            current.append(char)
    if escaped:
        return None
    fields.append("".join(current))
    return fields


def require_private_file(path, label):
    try:
        info = os.lstat(path)
    except OSError:
        fail(f"{label} are unavailable")
    if (not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode) or
            info.st_uid != os.getuid() or info.st_mode & 0o077):
        fail(f"{label} are unavailable")


def active_network():
    output = command("nmcli", "-t", "-f", "DEVICE,TYPE,STATE", "device")
    if output is None:
        fail("network readiness evidence is unavailable")
    active = []
    for line in output.splitlines():
        fields = split_terse(line)
        if fields and len(fields) == 3 and fields[2] == "connected":
            active.append((fields[0], fields[1]))
    for device, kind in active:
        if kind == "ethernet":
            return "ethernet", device
    for device, kind in active:
        if kind == "wifi":
            return "wifi", device
    fail("no ready Ethernet or Wi-Fi network is available")


def check_wifi_profile(expected_ssid):
    output = command("nmcli", "-t", "-f", "NAME,TYPE,AUTOCONNECT", "connection", "show")
    if output is None:
        fail("Wi-Fi profile evidence is unavailable")
    ssid_matched = False
    for line in output.splitlines():
        fields = split_terse(line)
        if not fields or len(fields) != 3:
            continue
        name, kind, autoconnect = fields
        if kind not in ("wifi", "802-11-wireless"):
            continue
        detail = command("nmcli", "-t", "-f", "802-11-wireless.ssid",
                         "connection", "show", "id", name)
        if detail is None:
            fail("Wi-Fi profile evidence is unavailable")
        for detail_line in detail.splitlines():
            detail_fields = split_terse(detail_line)
            if (detail_fields and len(detail_fields) == 2 and
                    detail_fields[0] == "802-11-wireless.ssid" and
                    detail_fields[1] == expected_ssid):
                if autoconnect == "yes":
                    return
                ssid_matched = True
    if ssid_matched:
        fail("expected Wi-Fi profile autoconnect is disabled")
    fail("expected Wi-Fi profile is not configured")


def wifi_evidence(expected_ssid):
    output = command("nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,RATE", "device", "wifi")
    if output is None:
        fail("Wi-Fi readiness evidence is unavailable")
    for line in output.splitlines():
        fields = split_terse(line)
        if fields is None or len(fields) != 4 or fields[0] != "*":
            continue
        if fields[1] != expected_ssid:
            fail("Wi-Fi association does not match owner overlay")
        rate_match = re.fullmatch(r"([0-9]+(?:\.[0-9]+)?) Mbit/s", fields[3])
        try:
            signal = int(fields[2])
            rate = float(rate_match.group(1))
        except (AttributeError, ValueError):
            fail("Wi-Fi signal or throughput evidence is invalid")
        return signal, rate
    fail("Wi-Fi association evidence is unavailable")


def ethernet_throughput(device):
    if not DEVICE_NAME.fullmatch(device):
        fail("Ethernet device evidence is invalid")
    output = command("ethtool", device)
    if output is None:
        fail("Ethernet throughput evidence is unavailable")
    match = re.search(r"^Speed:\s*([0-9.]+)Mb/s$", output, re.MULTILINE)
    if not match:
        fail("Ethernet throughput evidence is invalid")
    return float(match.group(1))


def check_tailnet(identity):
    output = command("tailscale", "status", "--json")
    if output is None:
        fail("tailnet evidence is unavailable")
    try:
        status = json.loads(output)
        backend = status["BackendState"]
        self_node = status["Self"]
        observed = self_node["DNSName"].rstrip(".")
        online = self_node["Online"]
    except (KeyError, TypeError, AttributeError, ValueError):
        fail("tailnet evidence is invalid")
    if backend != "Running" or online is not True:
        fail("tailnet is not running and online")
    if observed != identity.rstrip("."):
        fail("tailnet identity does not match owner overlay")


def check_storage(logical_id, declared, bound):
    mount = bound["mount"]
    output = command("findmnt", "--noheadings", "--output", "FSTYPE,OPTIONS",
                     "--target", mount)
    if output is None:
        fail(f"logical storage {logical_id} is not mounted")
    parts = output.split()
    if len(parts) != 2:
        fail(f"logical storage {logical_id} mount evidence is invalid")
    filesystem, options = parts
    if filesystem != declared["filesystem"]:
        fail(f"logical storage {logical_id} filesystem does not match profile")
    if declared["requires_write"]:
        if "ro" in options.split(","):
            fail(f"logical storage {logical_id} is mounted read-only")
        if not os.access(mount, os.W_OK | os.X_OK):
            fail(f"logical storage {logical_id} is not writable")
    output = command("df", "-P", "--", mount)
    try:
        used = int(output.splitlines()[1].split()[4].rstrip("%")) if output else None
    except (IndexError, ValueError):
        used = None
    if used is None:
        fail(f"logical storage {logical_id} capacity evidence is unavailable")
    if used >= declared["max_used_percent"]:
        fail(f"logical storage {logical_id} exceeds capacity threshold")


def main():
    global COMMAND_TIMEOUT
    parser = argparse.ArgumentParser(description="Preflight a Brokkr location profile")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--overlay", required=True)
    parser.add_argument("--command-timeout", type=float, default=DEFAULT_COMMAND_TIMEOUT,
                        help="upper bound in seconds for each external command")
    args = parser.parse_args()
    if not 0 < args.command_timeout <= 300:
        fail("command timeout is out of range")
    COMMAND_TIMEOUT = args.command_timeout

    profile = load_json(args.profile, "public profile")
    overlay = load_json(args.overlay, "owner overlay", private=True)
    PROFILE_SCHEMA(profile, "public profile", [])
    OVERLAY_SCHEMA(overlay, "owner overlay", [])

    location_name = overlay["location"]
    location = profile["locations"].get(location_name)
    if location is None:
        fail("owner overlay location is not declared by the public profile")
    declared_storage = location["storage"]
    if set(overlay["storage"]) != set(declared_storage):
        fail("owner overlay storage bindings do not match the public profile")
    for role in location["backup_roles"]:
        if role["logical_storage_id"] not in declared_storage:
            fail("backup role references undeclared logical storage")

    if location["tailnet"]["required"]:
        check_tailnet(overlay["tailnet_identity"])

    network = location["network"]
    overlay_wifi = overlay["wifi"]
    require_private_file(overlay_wifi["credentials_file"], "Wi-Fi credentials")
    if network["wifi"]["required"]:
        check_wifi_profile(overlay_wifi["ssid"])

    network_kind, device = active_network()
    if network_kind == "wifi":
        signal, throughput = wifi_evidence(overlay_wifi["ssid"])
        if signal < network["wifi"]["min_signal_percent"]:
            fail("Wi-Fi signal is below profile minimum")
        if throughput < network["wifi"]["min_throughput_mbps"]:
            fail("Wi-Fi throughput is below profile minimum")
    else:
        throughput = ethernet_throughput(device)
        if throughput < network["ethernet"]["min_throughput_mbps"]:
            fail("Ethernet throughput is below profile minimum")

    for logical_id, declared in declared_storage.items():
        check_storage(logical_id, declared, overlay["storage"][logical_id])
    for role in location["backup_roles"]:
        capacity_bytes = throughput * 1_000_000 / 8 * role["window_minutes"] * 60
        if role["bytes"] > capacity_bytes:
            fail("backup transfer window is insufficient")
    print(f"OK: location profile {location_name} preflight passed")


if __name__ == "__main__":
    try:
        main()
    except PreflightError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(2)
