#!/usr/bin/env python3
"""Report local Tailscale authentication and node-key expiry health."""

from __future__ import annotations

import datetime as dt
import ipaddress
import json
import math
import os
import re
import subprocess
import sys
import time


PASS = 0
WARN = 1
FAIL = 2
DEFAULT_WARN_SECS = 14 * 24 * 60 * 60
RFC3339 = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$"
)
DNS_NAME = re.compile(
    r"^(?=.{1,253}\.?$)[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.?$"
)


def finish(code: int, message: str) -> int:
    prefix = {PASS: "OK", WARN: "WARN", FAIL: "FAIL"}[code]
    print(f"{prefix}: {message}")
    return code


def positive_int(name: str, default: int) -> int | None:
    raw = os.environ.get(name, str(default))
    if not re.fullmatch(r"[1-9][0-9]*", raw):
        return None
    return int(raw)


def parse_rfc3339(value: object) -> dt.datetime | None:
    if not isinstance(value, str):
        return None
    match = RFC3339.fullmatch(value)
    if match is None:
        return None
    base, fraction, zone = match.groups()
    normalized = base
    if fraction:
        normalized += "." + (fraction + "000000")[:6]
    normalized += "+00:00" if zone == "Z" else zone
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        return None
    return parsed.astimezone(dt.timezone.utc)


def normalized_dns_name(value: object) -> str | None:
    if not isinstance(value, str) or not DNS_NAME.fullmatch(value):
        return None
    if value.endswith("."):
        value = value[:-1]
    if not value or ".." in value:
        return None
    return value.casefold()


def current_identity(status: dict[str, object]) -> bool:
    addresses = status.get("TailscaleIPs")
    if not isinstance(addresses, list) or not addresses:
        return False
    try:
        return all(isinstance(item, str) and ipaddress.ip_address(item) for item in addresses)
    except ValueError:
        return False


def main() -> int:
    policy = os.environ.get("BROKKR_TAILSCALE_KEY_EXPIRY_POLICY", "")
    if policy not in ("", "disabled", "monitored"):
        return finish(FAIL, "invalid key-expiry policy; expected disabled or monitored")

    warn_secs = positive_int("BROKKR_TAILSCALE_EXPIRY_WARN_SECS", DEFAULT_WARN_SECS)
    if warn_secs is None:
        return finish(FAIL, "invalid expiry warning threshold")
    timeout_secs = positive_int("BROKKR_TAILSCALE_STATUS_TIMEOUT_SECS", 5)
    if timeout_secs is None:
        return finish(FAIL, "invalid Tailscale status timeout")

    expected_raw = os.environ.get("BROKKR_TAILSCALE_EXPECTED_DNS_NAME", "")
    expected_dns = normalized_dns_name(expected_raw) if expected_raw else None
    if expected_raw and expected_dns is None:
        return finish(FAIL, "invalid expected tailnet identity configuration")

    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout_secs,
        )
    except subprocess.TimeoutExpired:
        return finish(FAIL, "Tailscale status command timed out")
    except (OSError, UnicodeError):
        return finish(FAIL, "Tailscale status command is unavailable")
    if result.returncode != 0:
        return finish(FAIL, "Tailscale status command failed")

    try:
        status = json.loads(result.stdout)
    except (json.JSONDecodeError, TypeError):
        return finish(FAIL, "invalid status JSON from Tailscale")
    if not isinstance(status, dict):
        return finish(FAIL, "invalid status JSON from Tailscale")

    backend = status.get("BackendState")
    if backend == "NeedsLogin":
        return finish(FAIL, "Tailscale authentication required; use the attended recovery runbook with fallback access")
    if backend != "Running":
        return finish(FAIL, "Tailscale is not running")

    self_status = status.get("Self")
    if not isinstance(self_status, dict):
        return finish(FAIL, "Tailscale self status is unavailable")
    if self_status.get("Online") is not True:
        return finish(FAIL, "Tailscale self node is not online")
    if not current_identity(status):
        return finish(FAIL, "Tailscale has no current tailnet identity")

    actual_dns = normalized_dns_name(self_status.get("DNSName"))
    if expected_dns is not None and actual_dns != expected_dns:
        return finish(FAIL, "tailnet identity mismatch")

    expired = self_status.get("Expired", False)
    if not isinstance(expired, bool):
        return finish(FAIL, "invalid key-expiry state from Tailscale")
    if expired:
        return finish(FAIL, "Tailscale node key has expired")

    key_expiry_raw = self_status.get("KeyExpiry")
    key_expiry = None
    if key_expiry_raw is not None:
        key_expiry = parse_rfc3339(key_expiry_raw)
        if key_expiry is None:
            return finish(FAIL, "invalid key expiry from Tailscale")

    now_raw = os.environ.get("BROKKR_NOW_EPOCH")
    if now_raw is None:
        now = time.time()
    elif re.fullmatch(r"[0-9]+", now_raw):
        now = float(now_raw)
    else:
        return finish(FAIL, "invalid observation clock")

    if key_expiry is not None:
        remaining = key_expiry.timestamp() - now
        if remaining <= 0:
            return finish(FAIL, "Tailscale node key has expired")
    else:
        remaining = None

    if policy == "":
        return finish(WARN, "Tailscale is healthy but key-expiry policy is not configured")
    if policy == "disabled":
        if key_expiry is not None:
            return finish(WARN, "Tailscale key-expiry policy drift: expiry is enabled but policy requires disabled")
        return finish(PASS, "Tailscale is Running and online with a current identity; key expiry is disabled by policy")

    if key_expiry is None:
        return finish(FAIL, "valid key expiry is unavailable for monitored policy")
    if remaining is not None and remaining <= warn_secs:
        days = max(1, math.ceil(remaining / 86400))
        return finish(WARN, f"Tailscale node key expires within {days} days; reauthenticate before monitoring is lost")
    return finish(PASS, "Tailscale is Running and online with a current identity; key expiry monitored")


if __name__ == "__main__":
    sys.exit(main())
