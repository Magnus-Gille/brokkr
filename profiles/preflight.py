#!/usr/bin/env python3
"""Fail-closed availability checks for Brokkr location profiles.

This script deliberately validates substrate facts only.  It never configures a
network, mounts storage, copies data, or invokes application-specific tooling.
"""
import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile


class PreflightError(Exception):
    """A safe, non-sensitive reason a preflight cannot proceed."""


def fail(message):
    raise PreflightError(message)


def load_json(path, label, private=False):
    try:
        info = os.lstat(path)
    except OSError:
        fail(f"{label} is unavailable")
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        fail(f"{label} must be a regular file")
    if private:
        if info.st_uid != os.getuid() or info.st_mode & 0o077:
            fail(f"{label} must be owned by the invoking user and mode 600")
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError):
        fail(f"{label} is invalid")
    if not isinstance(value, dict):
        fail(f"{label} is invalid")
    return value


def require(value, key, label):
    item = value.get(key)
    if item is None or item == "":
        fail(f"{label} is missing")
    return item


def command(*args):
    try:
        return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL).stdout
    except (OSError, subprocess.CalledProcessError):
        return None


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
        fields = line.split(":", 2)
        if len(fields) == 3 and fields[2] == "connected":
            active.append((fields[0], fields[1]))
    for device, kind in active:
        if kind == "ethernet":
            return "ethernet", device
    for device, kind in active:
        if kind == "wifi":
            return "wifi", device
    fail("no ready Ethernet or Wi-Fi network is available")


def wifi_evidence(expected_ssid):
    output = command("nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,RATE", "device", "wifi")
    if output is None:
        fail("Wi-Fi readiness evidence is unavailable")
    for line in output.splitlines():
        fields = line.split(":", 3)
        if len(fields) == 4 and fields[0] == "*":
            if fields[1] != expected_ssid:
                fail("Wi-Fi association does not match owner overlay")
            try:
                signal = int(fields[2])
                rate = float(re.search(r"[0-9.]+", fields[3]).group())
            except (AttributeError, ValueError):
                fail("Wi-Fi signal or throughput evidence is invalid")
            return signal, rate
    fail("Wi-Fi association evidence is unavailable")


def ethernet_throughput(device):
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
        fail("tailnet identity evidence is unavailable")
    try:
        observed = json.loads(output)["Self"]["DNSName"].rstrip(".")
    except (KeyError, TypeError, json.JSONDecodeError):
        fail("tailnet identity evidence is invalid")
    if observed != identity.rstrip("."):
        fail("tailnet identity does not match location profile")


def check_storage(logical_id, declared, bound):
    mount = require(bound, "mount", f"owner overlay storage binding for {logical_id}")
    filesystem = command("findmnt", "--target", mount, "--noheadings", "--output", "FSTYPE")
    if filesystem is None:
        fail(f"logical storage {logical_id} is not mounted")
    if filesystem.strip() != require(declared, "filesystem", f"storage {logical_id}"):
        fail(f"logical storage {logical_id} filesystem does not match profile")
    if declared.get("requires_write", False):
        try:
            with tempfile.NamedTemporaryFile(dir=mount, prefix=".brokkr-preflight-", delete=True):
                pass
        except OSError:
            fail(f"logical storage {logical_id} is not writable")
    output = command("df", "-P", mount)
    try:
        used = int(output.splitlines()[1].split()[4].rstrip("%")) if output else None
    except (IndexError, ValueError):
        used = None
    if used is None:
        fail(f"logical storage {logical_id} capacity evidence is unavailable")
    if used >= int(require(declared, "max_used_percent", f"storage {logical_id}")):
        fail(f"logical storage {logical_id} exceeds capacity threshold")


def main():
    parser = argparse.ArgumentParser(description="Preflight a Brokkr location profile")
    parser.add_argument("--profile", required=True)
    parser.add_argument("--overlay", required=True)
    args = parser.parse_args()
    profile = load_json(args.profile, "public profile")
    overlay = load_json(args.overlay, "owner overlay", private=True)
    if profile.get("schema_version") != 1 or overlay.get("schema_version") != 1:
        fail("unsupported profile schema version")
    location_name = require(overlay, "location", "owner overlay")
    locations = require(profile, "locations", "public profile")
    location = locations.get(location_name)
    if not isinstance(location, dict):
        fail("owner overlay location is not declared by public profile")
    check_tailnet(require(location, "tailnet_identity", "location profile"))
    network = require(location, "network", "location profile")
    wifi = require(network, "wifi", "location network profile")
    overlay_wifi = require(overlay, "wifi", "owner overlay")
    require_private_file(require(overlay_wifi, "credentials_file", "owner overlay Wi-Fi"), "Wi-Fi credentials")
    network_kind, device = active_network()
    if network_kind == "wifi":
        signal, throughput = wifi_evidence(require(overlay_wifi, "ssid", "owner overlay Wi-Fi"))
        if signal < int(require(wifi, "min_signal_percent", "Wi-Fi profile")):
            fail("Wi-Fi signal is below profile minimum")
    else:
        throughput = ethernet_throughput(device)
    if throughput < float(require(wifi, "min_throughput_mbps", "Wi-Fi profile")):
        fail("network throughput is below profile minimum")
    declared_storage = require(location, "storage", "location profile")
    bound_storage = require(overlay, "storage", "owner overlay")
    for logical_id, declared in declared_storage.items():
        bound = bound_storage.get(logical_id)
        if not isinstance(declared, dict) or not isinstance(bound, dict):
            fail(f"owner overlay storage binding for {logical_id} is missing")
        check_storage(logical_id, declared, bound)
    for role in require(location, "backup_roles", "location profile"):
        logical_id = require(role, "logical_storage_id", "backup role")
        if logical_id not in declared_storage:
            fail("backup role references undeclared logical storage")
        seconds = float(require(role, "window_minutes", "backup role")) * 60
        capacity_bytes = throughput * 1_000_000 / 8 * seconds
        if float(require(role, "bytes", "backup role")) > capacity_bytes:
            fail("backup transfer window is insufficient")
    print(f"OK: location profile {location_name} preflight passed")


if __name__ == "__main__":
    try:
        main()
    except PreflightError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(2)
