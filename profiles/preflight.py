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
DEVICE_NAME = re.compile(r"[A-Za-z0-9._-]{1,32}")
SCHEMA_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
DRAFT_2020_12_SCHEMA = "https://json-schema.org/draft/2020-12/schema"
SUPPORTED_SCHEMA_KEYWORDS = frozenset({
    "$schema", "$id", "$comment", "title", "description", "type", "const",
    "pattern", "properties", "required", "additionalProperties", "propertyNames",
    "minProperties", "items", "minItems", "minimum", "maximum",
    "exclusiveMinimum",
})
SCHEMA_TYPES = frozenset({"object", "array", "string", "integer", "number", "boolean"})

COMMAND_TIMEOUT = DEFAULT_COMMAND_TIMEOUT


class PreflightError(Exception):
    """A safe, non-sensitive reason a preflight cannot proceed."""


def fail(message):
    raise PreflightError(message)


def schema_fail(label, path, problem):
    where = ".".join(path) if path else "document"
    fail(f"{label} {where} {problem}")


def schema_comment(schema, default):
    """Return a safe diagnostic supplied by a tracked schema artifact."""
    comment = schema.get("$comment")
    return comment if isinstance(comment, str) else default


def validate_schema_artifact(schema, label, root=True):
    """Validate the deliberately small Draft 2020-12 vocabulary this runtime uses.

    This makes the artifacts executable specifications without a third-party JSON
    Schema dependency.  Rejecting unsupported keywords prevents a schema change
    from appearing to alter validation while the dependency-free runtime ignores it.
    """
    if not isinstance(schema, dict):
        fail(f"{label} is invalid")
    if set(schema) - SUPPORTED_SCHEMA_KEYWORDS:
        fail(f"{label} uses an unsupported schema keyword")
    if root and schema.get("$schema") != DRAFT_2020_12_SCHEMA:
        fail(f"{label} is not a Draft 2020-12 schema")
    for keyword in ("$schema", "$id", "$comment", "title", "description"):
        if keyword in schema and not isinstance(schema[keyword], str):
            fail(f"{label} is invalid")
    schema_type = schema.get("type")
    if schema_type is not None and schema_type not in SCHEMA_TYPES:
        fail(f"{label} is invalid")
    if "pattern" in schema:
        if not isinstance(schema["pattern"], str):
            fail(f"{label} is invalid")
        try:
            re.compile(schema["pattern"])
        except re.error:
            fail(f"{label} is invalid")
    for keyword in ("minimum", "maximum", "exclusiveMinimum"):
        if keyword in schema and (isinstance(schema[keyword], bool) or
                                  not isinstance(schema[keyword], (int, float)) or
                                  not math.isfinite(schema[keyword])):
            fail(f"{label} is invalid")
    for keyword in ("minProperties", "minItems"):
        if keyword in schema and (isinstance(schema[keyword], bool) or
                                  not isinstance(schema[keyword], int) or
                                  schema[keyword] < 0):
            fail(f"{label} is invalid")
    if "required" in schema:
        required = schema["required"]
        if (not isinstance(required, list) or any(not isinstance(key, str) for key in required)
                or len(required) != len(set(required))):
            fail(f"{label} is invalid")
    if "properties" in schema:
        if not isinstance(schema["properties"], dict):
            fail(f"{label} is invalid")
        for child in schema["properties"].values():
            validate_schema_artifact(child, label, root=False)
    if "additionalProperties" in schema:
        additional = schema["additionalProperties"]
        if not isinstance(additional, (bool, dict)):
            fail(f"{label} is invalid")
        if isinstance(additional, dict):
            validate_schema_artifact(additional, label, root=False)
    if "propertyNames" in schema:
        validate_schema_artifact(schema["propertyNames"], label, root=False)
    if "items" in schema:
        validate_schema_artifact(schema["items"], label, root=False)


def type_matches(value, schema_type):
    if schema_type == "object":
        return isinstance(value, dict)
    if schema_type == "array":
        return isinstance(value, list)
    if schema_type == "string":
        return isinstance(value, str)
    if schema_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if schema_type == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, bool)


def json_equal(left, right):
    """JSON value equality, without Python's True == 1 surprise."""
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left == right
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return math.isfinite(left) and math.isfinite(right) and left == right
    if type(left) is not type(right):
        return False
    if isinstance(left, list):
        return len(left) == len(right) and all(json_equal(a, b) for a, b in zip(left, right))
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(json_equal(left[key], right[key]) for key in left)
    return left == right


def validate_against_schema(value, schema, label, path=None):
    """Validate an instance against the supported schema subset."""
    path = [] if path is None else path
    schema_type = schema.get("type")
    if schema_type and not type_matches(value, schema_type):
        type_problem = {
            "boolean": "must be true or false",
            "integer": "must be an integer",
            "number": "must be a number",
        }.get(schema_type, f"must be a {schema_type}")
        schema_fail(label, path, type_problem)
    if "const" in schema and not json_equal(value, schema["const"]):
        schema_fail(label, path, schema_comment(schema, "does not match the schema"))
    if "pattern" in schema and (not isinstance(value, str) or
                                 not re.fullmatch(schema["pattern"], value)):
        schema_fail(label, path, schema_comment(schema, "does not match the required pattern"))
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not math.isfinite(value):
            schema_fail(label, path, schema_comment(schema, "must be a finite number"))
        if "minimum" in schema and value < schema["minimum"]:
            schema_fail(label, path, schema_comment(schema, "is out of range"))
        if "maximum" in schema and value > schema["maximum"]:
            schema_fail(label, path, schema_comment(schema, "is out of range"))
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            schema_fail(label, path, schema_comment(schema, "is out of range"))
    if isinstance(value, dict):
        if "minProperties" in schema and len(value) < schema["minProperties"]:
            schema_fail(label, path, schema_comment(schema, "must be a non-empty object"))
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                schema_fail(label, path + [key], "is missing")
        additional = schema.get("additionalProperties", True)
        for key, item in value.items():
            if "propertyNames" in schema:
                validate_against_schema(key, schema["propertyNames"], label, path)
            if key in properties:
                validate_against_schema(item, properties[key], label, path + [key])
            elif additional is False:
                schema_fail(label, path, "contains an unsupported field")
            elif isinstance(additional, dict):
                validate_against_schema(item, additional, label, path + [key])
    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            schema_fail(label, path, schema_comment(schema, "must not be empty"))
        if "items" in schema:
            for index, item in enumerate(value):
                validate_against_schema(item, schema["items"], label, path + [str(index)])


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


def load_schema(path, label):
    schema = load_json(path, label)
    validate_schema_artifact(schema, label)
    return schema


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
    if os.path.normpath(mount) != mount or os.path.realpath(mount) != mount:
        fail(f"logical storage {logical_id} mount path is not canonical")
    output = command("findmnt", "--json", "--output", "TARGET,FSTYPE,OPTIONS",
                     "--target", mount)
    if output is None:
        fail(f"logical storage {logical_id} is not mounted")
    try:
        filesystems = json.loads(output)["filesystems"]
        if not isinstance(filesystems, list) or len(filesystems) != 1:
            raise ValueError
        evidence = filesystems[0]
        target = evidence["target"]
        filesystem = evidence["fstype"]
        options = evidence["options"]
        if not all(isinstance(item, str) for item in (target, filesystem, options)):
            raise ValueError
    except (KeyError, TypeError, ValueError):
        fail(f"logical storage {logical_id} mount evidence is invalid")
    if target != mount:
        fail(f"logical storage {logical_id} mount target does not match profile")
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
    parser.add_argument("--profile-schema",
                        default=os.path.join(SCHEMA_DIRECTORY,
                                             "location-network-storage.schema.json"))
    parser.add_argument("--overlay-schema",
                        default=os.path.join(SCHEMA_DIRECTORY,
                                             "location-network-storage.overlay.schema.json"))
    parser.add_argument("--command-timeout", type=float, default=DEFAULT_COMMAND_TIMEOUT,
                        help="upper bound in seconds for each external command")
    args = parser.parse_args()
    if not 0 < args.command_timeout <= 300:
        fail("command timeout is out of range")
    COMMAND_TIMEOUT = args.command_timeout

    profile = load_json(args.profile, "public profile")
    overlay = load_json(args.overlay, "owner overlay", private=True)
    profile_schema = load_schema(args.profile_schema, "public profile schema")
    overlay_schema = load_schema(args.overlay_schema, "owner overlay schema")
    validate_against_schema(profile, profile_schema, "public profile")
    validate_against_schema(overlay, overlay_schema, "owner overlay")

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

    tailnet_identity = overlay.get("tailnet_identity")
    if location["tailnet"]["required"] and tailnet_identity is None:
        fail("owner overlay tailnet identity is required by location")
    if tailnet_identity is not None:
        check_tailnet(tailnet_identity)

    network = location["network"]
    overlay_wifi = overlay.get("wifi")
    if network["wifi"]["required"] and overlay_wifi is None:
        fail("owner overlay Wi-Fi evidence is required by location")
    if overlay_wifi is not None:
        require_private_file(overlay_wifi["credentials_file"], "Wi-Fi credentials")
        check_wifi_profile(overlay_wifi["ssid"])

    network_kind, device = active_network()
    if network_kind == "wifi":
        if overlay_wifi is None:
            fail("owner overlay Wi-Fi evidence is required for active Wi-Fi")
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
