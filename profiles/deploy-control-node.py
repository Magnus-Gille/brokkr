#!/usr/bin/env python3
"""Execute a control-node deployment from an owner-only locator overlay.

The public schema and example explain the required shape without committing a
host, account, filesystem locator, endpoint, or token-source locator.  This
wrapper deliberately passes values as environment entries and argv, never by
sourcing an overlay or constructing a shell command.
"""
import argparse
import os
import posixpath
import re
import subprocess
import sys
from urllib.parse import urlsplit

from preflight import PreflightError, load_json, load_schema, validate_against_schema

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "control-node-deploy.overlay.schema.json")
DEPLOY = os.path.join(ROOT, "scripts", "deploy-control-node.sh")
FULL_SHA = re.compile(r"(?:[0-9a-f]{40}|[0-9a-f]{64})\Z")
SSH_TARGET = re.compile(r"(?:[a-z_][a-z0-9_-]{0,31}@)?[A-Za-z0-9][A-Za-z0-9.-]{0,251}\Z")
RUNTIME_USER = re.compile(r"[a-z_][a-z0-9_-]{0,31}\Z")
HOSTNAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,251}\Z")


def fail(message):
    print(f"brokkr deploy profile: {message}", file=sys.stderr)
    raise SystemExit(64)


def require_canonical_path(value, field):
    if (not isinstance(value, str) or value == "/" or not value.startswith("/") or
            "//" in value or posixpath.normpath(value) != value or
            any(part in ("", ".", "..") for part in value.split("/")[1:])):
        fail(f"control-node deployment overlay {field} must be a non-root canonical absolute path")


def require_endpoint(value):
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError:
        fail("control-node deployment overlay heimdall_url must be a strict HTTP(S) endpoint")
    if (parsed.scheme not in ("http", "https") or not parsed.netloc or
            parsed.username is not None or parsed.password is not None or
            parsed.query or parsed.fragment or not parsed.hostname or
            not HOSTNAME.fullmatch(parsed.hostname) or
            (parsed.path and (not parsed.path.startswith("/") or "//" in parsed.path or
                              posixpath.normpath(parsed.path) != parsed.path)) or
            (port is not None and not 1 <= port <= 65535)):
        fail("control-node deployment overlay heimdall_url must be a strict HTTP(S) endpoint")


def validate_overlay_semantics(overlay):
    """Apply the deployment script's exact safety grammar, beyond JSON Schema."""
    if not SSH_TARGET.fullmatch(overlay["ssh_target"]):
        fail("control-node deployment overlay ssh_target must be a strict SSH target")
    if not RUNTIME_USER.fullmatch(overlay["runtime_user"]):
        fail("control-node deployment overlay runtime_user must be a strict runtime user")
    for field in ("deploy_target", "runtime_home", "registry_path", "heimdall_token_source"):
        require_canonical_path(overlay[field], field)
    require_endpoint(overlay["heimdall_url"])


def main():
    parser = argparse.ArgumentParser(description="Deploy Brokkr control-node from a private overlay")
    parser.add_argument("--overlay", required=True, help="owner-only mode-0600 JSON overlay")
    parser.add_argument("--commit", required=True, help="accepted lowercase full source revision")
    args = parser.parse_args()
    if not FULL_SHA.fullmatch(args.commit):
        fail("--commit must be a lowercase 40- or 64-character full SHA")
    try:
        schema = load_schema(SCHEMA, "control-node deployment overlay schema")
        overlay = load_json(args.overlay, "control-node deployment overlay", private=True)
        validate_against_schema(overlay, schema, "control-node deployment overlay")
    except PreflightError as error:
        fail(str(error))
    validate_overlay_semantics(overlay)
    environment = dict(os.environ)
    environment.update({
        "BROKKR_EXPECTED_SOURCE": ROOT,
        "BROKKR_EXPECTED_COMMIT": args.commit,
        "BROKKR_SSH_TARGET": overlay["ssh_target"],
        "BROKKR_DEPLOY_TARGET": overlay["deploy_target"],
        "BROKKR_RUNTIME_USER": overlay["runtime_user"],
        "BROKKR_RUNTIME_HOME": overlay["runtime_home"],
        "BROKKR_REGISTRY_PATH": overlay["registry_path"],
        "BROKKR_HEIMDALL_URL": overlay["heimdall_url"],
        "BROKKR_HEIMDALL_TOKEN_SOURCE": overlay["heimdall_token_source"],
    })
    completed = subprocess.run([DEPLOY, overlay["ssh_target"]], cwd=ROOT, env=environment)
    raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
