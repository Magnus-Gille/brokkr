#!/usr/bin/env python3
"""Preflight for moving control-node SSH from Tailscale SSH to OpenSSH.

The preflight itself makes no connection to the target and writes nothing. It only runs
`tailscale status --json`, `ssh -G`, `ssh-keygen -F`, `sshd -T -C ...` and
`systemctl is-active`, and reads local files. These commands run as the caller: in
particular `ssh -G` evaluates the workstation's client configuration exactly as `ssh`
would, including any `Match exec` commands in it, so review that configuration first.

Roles:
  operator  run on the operator workstation before/after the cutover
  host      run on the control node (as root, for `sshd -T` and other users' keys)

The host role evaluates sshd for the real connection context, so `Match` blocks apply:
it runs `sshd -T -C user=<ssh-user>,host=<client>,addr=<client>,laddr=<laddr>,lport=22`
for the operator's login and a second time with `user=root` for the root-login rule.
<client> is --client-address (the operator workstation's tailnet address) and <laddr> is
this node's first tailnet address of the same IP version. If there is none, the check
is blocked with client_address_family_unavailable.

From those outputs the host role requires: public-key login on; password and
keyboard-interactive off; PermitRootLogin "no" in the root context (the key-based values
are blocked because AuthorizedKeysCommand or certificates can authorize root without a
local key file); UseDNS "no"; a port-22 listener that is laddr or the unspecified address
of laddr's family; DenyUsers/AllowUsers/DenyGroups/AllowGroups that admit the operator
(user@host patterns are matched against the client address); and at least one usable key
in authorized_keys files that pass OpenSSH's StrictModes path check.

Output is exactly one line of JSON on stdout and nothing on stderr. It carries only
booleans, integer counts and short snake_case codes: never hostnames, addresses,
user names, fingerprints, key material, paths or raw command output. Only the checks
that were actually evaluated appear under "checks"; an early blocked or error result
omits the rest instead of reporting them as false.
Exit status: 0 pass, 2 blocked, 1 error.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import fnmatch
import grp
import hashlib
import ipaddress
import json
import os
import pwd
import re
import shutil
import stat
import subprocess
import sys
from typing import NamedTuple, Union


SCHEMA_VERSION = "v1"
EXIT_CODES = {"pass": 0, "error": 1, "blocked": 2}
ROLES = ("operator", "host")
PHASES = ("before", "after")
DEFAULT_TIMEOUT_SECS = 10
MAX_TIMEOUT_SECS = 86400

DNS_LABEL = r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"
DNS_NAME = re.compile(rf"{DNS_LABEL}(?:\.{DNS_LABEL})+")
SSH_ALIAS = re.compile(r"[A-Za-z0-9._-]+")
FINGERPRINT = re.compile(r"SHA256:[A-Za-z0-9+/]{43}")
USERNAME = re.compile(r"[a-z_][a-z0-9_-]{0,31}")
TIMEOUT = re.compile(r"[1-9][0-9]*")

STRICT_HOST_KEY_CHECKING_OK = frozenset({"true", "yes", "ask"})
AUTHORIZED_KEY_TYPES = frozenset(
    {
        "ssh-ed25519",
        "ssh-rsa",
        "ecdsa-sha2-nistp256",
        "ecdsa-sha2-nistp384",
        "ecdsa-sha2-nistp521",
        "sk-ssh-ed25519@openssh.com",
        "sk-ecdsa-sha2-nistp256@openssh.com",
    }
)
SSHD_UNITS = ("ssh.service", "ssh.socket", "sshd.service")
DEFAULT_AUTHORIZED_KEYS_FILES = (".ssh/authorized_keys", ".ssh/authorized_keys2")

IPAddress = Union[ipaddress.IPv4Address, ipaddress.IPv6Address]


class Abort(Exception):
    """Internal control flow: stop the check with a single error code."""

    def __init__(self, code: str) -> None:
        super().__init__(code)
        self.code = code


class Account(NamedTuple):
    name: str
    uid: int
    home: str
    gid: int


class Report:
    """Accumulates booleans, counts, reasons (blocking) and warnings."""

    def __init__(self, role: str, phase: str) -> None:
        self.role = role
        self.phase = phase
        self.checks: dict[str, bool] = {}
        self.counts: dict[str, int] = {}
        self.reasons: set[str] = set()
        self.warnings: set[str] = set()

    def check(self, name: str, ok: bool, reason: str | None = None) -> bool:
        self.checks[name] = bool(ok)
        if not ok and reason is not None:
            self.reasons.add(reason)
        return bool(ok)

    def outcome(self) -> str:
        return "blocked" if self.reasons else "pass"


def render(
    role: str | None,
    phase: str | None,
    outcome: str,
    checks: dict[str, bool],
    reasons: set[str],
    warnings: set[str],
    counts: dict[str, int],
) -> str:
    payload = {
        "schema_version": SCHEMA_VERSION,
        "role": role,
        "phase": phase,
        "outcome": outcome,
        "checks": {name: checks[name] for name in sorted(checks)},
        "reasons": sorted(reasons),
        "warnings": sorted(warnings),
        "counts": {name: counts[name] for name in sorted(counts)},
    }
    return json.dumps(payload, separators=(",", ":"))


# ---------------------------------------------------------------- arguments


class QuietParser(argparse.ArgumentParser):
    """argparse that reports failures as an error code instead of printing usage."""

    def error(self, message):  # noqa: ARG002 - argparse hook signature
        raise Abort("invalid_arguments")

    def exit(self, status=0, message=None):  # noqa: ARG002 - argparse hook signature
        raise Abort("invalid_arguments")


def build_parser() -> QuietParser:
    parser = QuietParser(add_help=False, allow_abbrev=False)
    roles = parser.add_subparsers(dest="role", parser_class=QuietParser)
    roles.required = True

    operator = roles.add_parser("operator", add_help=False, allow_abbrev=False)
    operator.add_argument("--phase", required=True, choices=PHASES)
    operator.add_argument("--target-dns-name", required=True)
    operator.add_argument("--ssh-host", required=True)
    operator.add_argument("--expected-host-key-fingerprint", required=True)

    host = roles.add_parser("host", add_help=False, allow_abbrev=False)
    host.add_argument("--phase", required=True, choices=PHASES)
    host.add_argument("--ssh-user", required=True)
    host.add_argument("--client-address", required=True)
    return parser


def hint_role_phase(argv: list[str]) -> tuple[str | None, str | None]:
    """Best-effort role/phase for an error report; only enumerated values are echoed."""
    role = argv[0] if argv and argv[0] in ROLES else None
    phase = None
    for index, item in enumerate(argv):
        if item == "--phase" and index + 1 < len(argv) and argv[index + 1] in PHASES:
            phase = argv[index + 1]
        elif item.startswith("--phase=") and item[len("--phase="):] in PHASES:
            phase = item[len("--phase="):]
    return role, phase


def command_timeout() -> int:
    raw = os.environ.get("BROKKR_CUTOVER_TIMEOUT_SECS", str(DEFAULT_TIMEOUT_SECS))
    if TIMEOUT.fullmatch(raw) is None or int(raw) > MAX_TIMEOUT_SECS:
        raise Abort("invalid_arguments")
    return int(raw)


def normalize_dns_name(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    if value.endswith("."):
        value = value[:-1]
    if len(value) > 253 or DNS_NAME.fullmatch(value) is None:
        return None
    return value.casefold()


# --------------------------------------------------------------- subprocesses


def run_command(argv: list[str], timeout: int, code: str, timeout_code: str | None = None):
    """Run a read-only command; map the expected failure modes to specific codes."""
    try:
        return subprocess.run(
            argv,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        raise Abort(timeout_code or code) from None
    except (OSError, UnicodeError):
        raise Abort(code) from None


def load_tailscale_status(timeout: int) -> dict:
    result = run_command(
        ["tailscale", "status", "--json"],
        timeout,
        "tailscale_status_unavailable",
        "tailscale_status_timeout",
    )
    if result.returncode != 0:
        raise Abort("tailscale_status_failed")
    try:
        status = json.loads(result.stdout)
    except (ValueError, RecursionError):  # JSONDecodeError, oversized numbers, deep nesting
        raise Abort("tailscale_status_invalid") from None
    if not isinstance(status, dict):
        raise Abort("tailscale_status_invalid")
    return status


def parse_keyed_lines(text: str) -> dict[str, list[str]]:
    """Parse `key value...` lines (ssh -G, sshd -T) into lowercase-key lists."""
    parsed: dict[str, list[str]] = {}
    for line in text.splitlines():
        parts = line.strip().split(None, 1)
        if parts:
            parsed.setdefault(parts[0].lower(), []).append(parts[1].strip() if len(parts) > 1 else "")
    return parsed


def first_value(config: dict[str, list[str]], key: str) -> str | None:
    values = config.get(key)
    return values[0] if values else None


def tokens(config: dict[str, list[str]], key: str) -> list[str]:
    return [token for line in config.get(key, []) for token in line.split()]


def key_fingerprint(blob: str) -> str:
    """OpenSSH SHA256 fingerprint of a base64 public-key blob (as `ssh-keygen -lf`)."""
    if not blob:
        raise ValueError("empty key blob")
    digest = hashlib.sha256(base64.b64decode(blob, validate=True)).digest()
    return "SHA256:" + base64.b64encode(digest).decode("ascii").rstrip("=")


# ------------------------------------------------------------------- operator


def advertised_host_keys(node: dict) -> list[str]:
    keys = node.get("sshHostKeys")
    if keys is None:
        return []
    if not isinstance(keys, list) or not all(isinstance(item, str) for item in keys):
        raise Abort("tailscale_status_invalid")
    return keys


def advertises_tailscale_ssh(node: object) -> bool:
    return isinstance(node, dict) and isinstance(node.get("sshHostKeys"), list) and bool(node["sshHostKeys"])


def advertised_fingerprints(keys: list[str]) -> set[str]:
    fingerprints: set[str] = set()
    for entry in keys:
        fields = entry.split()
        if len(fields) < 2:
            raise Abort("tailscale_status_invalid")
        try:
            fingerprints.add(key_fingerprint(fields[1]))
        except (ValueError, binascii.Error):
            raise Abort("tailscale_status_invalid") from None
    return fingerprints


def parse_found_entries(text: str) -> tuple[list[str], list[str]]:
    """Fingerprints of plain and @revoked entries in `ssh-keygen -F` output."""
    plain: list[str] = []
    revoked: list[str] = []
    for line in text.splitlines():
        fields = line.split()
        if not fields or fields[0].startswith("#"):
            continue
        marker = fields.pop(0) if fields[0].startswith("@") else None
        if marker == "@cert-authority":
            continue
        if marker not in (None, "@revoked") or len(fields) < 3:
            raise ValueError("unrecognised known_hosts entry")
        fingerprint = key_fingerprint(fields[2])
        (revoked if marker else plain).append(fingerprint)
    return plain, revoked


def known_hosts_paths(config: dict[str, list[str]]) -> list[str]:
    paths: list[str] = []
    for key in ("userknownhostsfile", "globalknownhostsfile"):
        for item in tokens(config, key):
            if item.casefold() == "none":
                continue
            path = os.path.expanduser(item)
            if path not in paths:
                paths.append(path)
    return paths


def lookup_known_hosts(name: str, paths: list[str], timeout: int) -> tuple[list[str], list[str]]:
    plain: list[str] = []
    revoked: list[str] = []
    for path in paths:
        if not os.path.isfile(path):
            continue
        result = run_command(["ssh-keygen", "-F", name, "-f", path], timeout, "known_hosts_lookup_failed")
        if result.returncode == 1:
            continue
        if result.returncode != 0:
            raise Abort("known_hosts_lookup_failed")
        try:
            found_plain, found_revoked = parse_found_entries(result.stdout)
        except (ValueError, binascii.Error):
            raise Abort("known_hosts_lookup_failed") from None
        plain.extend(found_plain)
        revoked.extend(found_revoked)
    return plain, revoked


def run_operator(args: argparse.Namespace, timeout: int) -> Report:
    report = Report("operator", args.phase)
    target = normalize_dns_name(args.target_dns_name)
    if (
        target is None
        or SSH_ALIAS.fullmatch(args.ssh_host) is None
        or args.ssh_host.startswith("-")
        or FINGERPRINT.fullmatch(args.expected_host_key_fingerprint) is None
    ):
        raise Abort("invalid_arguments")
    expected = args.expected_host_key_fingerprint

    status = load_tailscale_status(timeout)
    if not report.check("tailscale_running", status.get("BackendState") == "Running", "tailscale_not_running"):
        return report

    peers = status.get("Peer")
    if peers is None:
        peers = {}
    if not isinstance(peers, dict) or not all(isinstance(peer, dict) for peer in peers.values()):
        raise Abort("tailscale_status_invalid")
    matches = [peer for peer in peers.values() if normalize_dns_name(peer.get("DNSName")) == target]
    report.checks["target_found"] = len(matches) == 1
    if not matches:
        report.reasons.add("target_not_found")
        return report
    if len(matches) > 1:
        report.reasons.add("target_ambiguous")
        return report
    peer = matches[0]

    report.check("target_online", peer.get("Online") is True, "target_offline")

    host_keys = advertised_host_keys(peer)
    advertised = bool(host_keys)
    report.checks["target_advertises_tailscale_ssh"] = advertised
    if args.phase == "before" and not advertised:
        report.reasons.add("tailscale_ssh_not_advertised")
    if args.phase == "after" and advertised:
        report.reasons.add("tailscale_ssh_still_advertised")

    others = [node for node in peers.values() if node is not peer]
    others.append(status.get("Self"))
    report.counts["other_tailscale_ssh_nodes"] = sum(1 for node in others if advertises_tailscale_ssh(node))
    if report.counts["other_tailscale_ssh_nodes"] > 0:
        report.warnings.add("other_tailscale_ssh_nodes_present")

    result = run_command(["ssh", "-G", args.ssh_host], timeout, "ssh_config_unavailable")
    if result.returncode != 0:
        raise Abort("ssh_config_unavailable")
    config = parse_keyed_lines(result.stdout)
    hostname = first_value(config, "hostname")
    port = first_value(config, "port")
    user = first_value(config, "user")
    if not hostname or not port or not user:
        raise Abort("ssh_config_unavailable")

    tailnet_ips = peer.get("TailscaleIPs")
    tailnet_ips = [ip for ip in tailnet_ips if isinstance(ip, str)] if isinstance(tailnet_ips, list) else []
    name = hostname.casefold()
    name = name[:-1] if name.endswith(".") else name
    report.check(
        "ssh_route_tailnet",
        name in (target, target.split(".")[0]) or hostname in tailnet_ips,
        "ssh_route_not_tailnet",
    )
    proxied = any(
        value.strip().casefold() != "none"
        for key in ("proxyjump", "proxycommand")
        for value in config.get(key, [])
    )
    report.check("ssh_route_unproxied", not proxied, "ssh_route_proxied")
    report.check("ssh_port_22", port == "22", "ssh_port_not_22")
    report.check("ssh_user_not_root", user != "root", "ssh_user_root")
    strict = first_value(config, "stricthostkeychecking")
    report.check(
        "strict_host_key_checking_enforced",
        strict is not None and strict.casefold() in STRICT_HOST_KEY_CHECKING_OK,
        "strict_host_key_checking_weak",
    )

    alias = first_value(config, "hostkeyalias")
    lookup_name = alias if alias and alias.casefold() != "none" else hostname
    plain, revoked = lookup_known_hosts(lookup_name, known_hosts_paths(config), timeout)
    report.counts["known_hosts_entries"] = len(plain)
    is_revoked = expected in revoked
    has_expected = expected in plain and not is_revoked
    report.checks["known_hosts_has_expected_key"] = has_expected
    if is_revoked:
        report.reasons.add("expected_host_key_revoked")
    elif not has_expected:
        report.reasons.add("known_hosts_missing_expected_key")

    if args.phase == "before":
        presents = expected in advertised_fingerprints(host_keys)
        report.checks["tailscale_ssh_presents_expected_key"] = presents
        if not presents:
            report.warnings.add("tailscale_ssh_host_key_differs")
    return report


# ----------------------------------------------------------------------- host


def expand_authorized_keys_path(template: str, home: str, user: str, uid: int) -> str:
    """Expand sshd AuthorizedKeysFile tokens; relative paths are relative to home."""
    replacements = {"%": "%", "h": home, "u": user, "U": str(uid)}
    path = re.sub(r"%([%huU])", lambda match: replacements[match.group(1)], template)
    return path if os.path.isabs(path) else os.path.join(home, path)


def unsafe_owner_or_mode(info: os.stat_result, uid: int) -> bool:
    """OpenSSH safe_path(): not owned by root or the user, or writable by group/other."""
    return info.st_uid not in (0, uid) or bool(info.st_mode & 0o022)


def safe_path(path: str, info: os.stat_result, account: Account) -> bool:
    """Mirror OpenSSH misc.c safe_path() as used with StrictModes.

    The canonical file must be regular, owned by root or the user and not group- or
    world-writable. Every directory above it, up to and including the canonical home
    directory (or /), must satisfy the same ownership and mode rule.
    """
    if not stat.S_ISREG(info.st_mode) or unsafe_owner_or_mode(info, account.uid):
        return False
    current = os.path.realpath(path)
    home = os.path.realpath(account.home) if account.home and os.path.isdir(account.home) else None
    while True:
        current = os.path.dirname(current)
        try:
            directory = os.stat(current)
        except OSError:
            return False
        if unsafe_owner_or_mode(directory, account.uid):
            return False
        if home is not None and current == home:
            return True
        if current in ("/", "."):
            return True


def blob_has_type(blob: str, key_type: str) -> bool:
    """True if a base64 public-key blob's first SSH wire string is `key_type`."""
    try:
        raw = base64.b64decode(blob, validate=True)
    except (ValueError, binascii.Error):
        return False
    if len(raw) < 4:
        return False
    length = int.from_bytes(raw[:4], "big")
    return length > 0 and raw[4:4 + length] == key_type.encode("ascii") and len(raw) >= 4 + length


def classify_authorized_keys_line(line: bytes) -> str:
    """Return "skip", "key", "options" or "invalid" for one authorized_keys line."""
    fields = line.decode("utf-8", errors="replace").split()
    if not fields or fields[0].startswith("#"):
        return "skip"
    if fields[0] in AUTHORIZED_KEY_TYPES:
        return "key" if len(fields) >= 2 and blob_has_type(fields[1], fields[0]) else "invalid"
    for index in range(1, len(fields) - 1):
        if fields[index] in AUTHORIZED_KEY_TYPES and blob_has_type(fields[index + 1], fields[index]):
            return "options"
    return "invalid"


class KeyScan(NamedTuple):
    count: int
    unsafe: bool
    options_lines: bool
    invalid_lines: bool


def authorized_keys_state(templates: list[str], account: Account) -> KeyScan:
    """Usable-key count and findings over the existing key files.

    A file that fails safe_path() is ignored by OpenSSH, so it contributes no keys and
    is reported as unsafe. Only lines that start with a known key type and a matching
    blob count; options-prefixed keys are not evaluated and only produce a warning.
    """
    count = 0
    unsafe = options_lines = invalid_lines = False
    seen: set[str] = set()
    for template in templates:
        path = expand_authorized_keys_path(template, account.home, account.name, account.uid)
        if path in seen:
            continue
        seen.add(path)
        try:
            info = os.stat(path)
        except (FileNotFoundError, NotADirectoryError):
            continue
        except OSError:
            raise Abort("authorized_keys_unreadable") from None
        if not safe_path(path, info, account):
            unsafe = True
            continue
        try:
            with open(path, "rb") as handle:
                data = handle.read()
        except OSError:
            raise Abort("authorized_keys_unreadable") from None
        for line in data.splitlines():
            kind = classify_authorized_keys_line(line)
            if kind == "key":
                count += 1
            elif kind == "options":
                options_lines = True
            elif kind == "invalid":
                invalid_lines = True
    return KeyScan(count, unsafe, options_lines, invalid_lines)


def parse_listen_address(value: str) -> tuple[IPAddress, int] | None:
    if value.startswith("["):
        host, bracket, rest = value[1:].partition("]")
        if not bracket or not rest.startswith(":"):
            return None
        port = rest[1:]
    else:
        host, colon, port = value.rpartition(":")
        if not colon:
            return None
    if re.fullmatch(r"[0-9]{1,5}", port) is None:
        return None
    try:
        return ipaddress.ip_address(host), int(port)
    except ValueError:
        return None


def tailnet_addresses(status: dict) -> list[IPAddress]:
    raw = status.get("TailscaleIPs")
    if raw is None:
        return []
    if not isinstance(raw, list) or not all(isinstance(item, str) for item in raw):
        raise Abort("tailscale_status_invalid")
    try:
        return [ipaddress.ip_address(item) for item in raw]
    except ValueError:
        raise Abort("tailscale_status_invalid") from None


def account_for(name: str) -> Account | None:
    try:
        entry = pwd.getpwnam(name)
    except KeyError:
        return None
    return Account(entry.pw_name, entry.pw_uid, entry.pw_dir, entry.pw_gid)


def account_groups(account: Account) -> set[str] | None:
    """Group names as sshd resolves them (getgrouplist); None if the lookup fails.

    Like OpenSSH's ga_init(), group ids without a name are skipped.
    """
    try:
        gids = os.getgrouplist(account.name, account.gid)
    except OSError:
        return None
    names: set[str] = set()
    for gid in gids:
        try:
            names.add(grp.getgrgid(gid).gr_name)
        except KeyError:
            continue
    return names


def user_pattern_verdict(pattern: str, user: str, client: IPAddress) -> bool | None:
    """Match an AllowUsers/DenyUsers pattern; None if it cannot be evaluated here.

    `user@host` patterns are evaluated against the client address (UseDNS is required
    to be off, so the host is the address). Negation and host lists are not evaluated.
    """
    user_part, at, host_part = pattern.partition("@")
    if "!" in user_part:
        return None
    if not fnmatch.fnmatchcase(user, user_part):
        return False
    if not at:
        return True
    if "!" in host_part or "," in host_part:
        return None
    try:
        return client in ipaddress.ip_network(host_part, strict=False)
    except ValueError:
        return fnmatch.fnmatchcase(str(client), host_part)


def group_pattern_verdict(pattern: str, groups: set[str]) -> bool | None:
    if "!" in pattern:
        return None
    return any(fnmatch.fnmatchcase(name, pattern) for name in groups)


def check_access_filters(report: Report, config: dict[str, list[str]], account: Account, client: IPAddress) -> None:
    """Evaluate DenyUsers, AllowUsers, DenyGroups and AllowGroups (OpenSSH order)."""
    deny_users = [user_pattern_verdict(p, account.name, client) for p in tokens(config, "denyusers")]
    allow_users = [user_pattern_verdict(p, account.name, client) for p in tokens(config, "allowusers")]
    deny_group_patterns = tokens(config, "denygroups")
    allow_group_patterns = tokens(config, "allowgroups")
    unevaluated = any(verdict is None for verdict in deny_users + allow_users)
    deny_groups: list[bool | None] = []
    allow_groups: list[bool | None] = []
    if deny_group_patterns or allow_group_patterns:
        groups = account_groups(account)
        if groups is None:
            unevaluated = True
        else:
            deny_groups = [group_pattern_verdict(p, groups) for p in deny_group_patterns]
            allow_groups = [group_pattern_verdict(p, groups) for p in allow_group_patterns]
            unevaluated = unevaluated or any(verdict is None for verdict in deny_groups + allow_groups)

    reasons: set[str] = set()
    if unevaluated:
        reasons.add("access_filter_not_evaluated")
    if True in deny_users:
        reasons.add("operator_user_denied")
    if allow_users and True not in allow_users and None not in allow_users:
        reasons.add("operator_user_not_allowed")
    if True in deny_groups:
        reasons.add("operator_group_denied")
    if allow_groups and True not in allow_groups and None not in allow_groups:
        reasons.add("operator_group_not_allowed")
    report.checks["operator_user_permitted"] = not reasons
    report.reasons.update(reasons)


def parse_client_address(value: str) -> IPAddress:
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        raise Abort("invalid_arguments") from None
    if getattr(address, "scope_id", None):
        raise Abort("invalid_arguments")
    return address


def load_sshd_config(user: str, client: IPAddress, listen: IPAddress, timeout: int) -> dict[str, list[str]]:
    """`sshd -T` evaluated for one connection context, so Match blocks are applied."""
    spec = f"user={user},host={client},addr={client},laddr={listen},lport=22"
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    result = run_command([sshd, "-T", "-C", spec], timeout, "sshd_config_unavailable")
    config = parse_keyed_lines(result.stdout)
    if result.returncode != 0 or not config:
        raise Abort("sshd_config_unavailable")
    return config


def authorized_keys_templates(config: dict[str, list[str]]) -> list[str]:
    if "authorizedkeysfile" not in config:
        return list(DEFAULT_AUTHORIZED_KEYS_FILES)
    return [item for item in tokens(config, "authorizedkeysfile") if item.casefold() != "none"]


def run_host(args: argparse.Namespace, timeout: int) -> Report:
    report = Report("host", args.phase)
    if USERNAME.fullmatch(args.ssh_user) is None or args.ssh_user == "root":
        raise Abort("invalid_arguments")
    client = parse_client_address(args.client_address)
    operator = account_for(args.ssh_user)
    if operator is None:
        report.checks["operator_user_exists"] = False
        report.reasons.add("operator_user_missing")
        return report
    report.checks["operator_user_exists"] = True

    status = load_tailscale_status(timeout)
    if not report.check("tailscale_running", status.get("BackendState") == "Running", "tailscale_not_running"):
        return report
    self_node = status.get("Self")
    report.check("self_online", isinstance(self_node, dict) and self_node.get("Online") is True, "self_offline")
    tailnet = tailnet_addresses(status)

    # The connection arrives on this node's tailnet address of the client's family.
    listen = next((address for address in tailnet if address.version == client.version), None)
    if not report.check("client_address_family_available", listen is not None, "client_address_family_unavailable"):
        return report
    config = load_sshd_config(operator.name, client, listen, timeout)
    root_config = load_sshd_config("root", client, listen, timeout)

    report.check(
        "pubkey_auth_enabled",
        (first_value(config, "pubkeyauthentication") or "").casefold() == "yes",
        "pubkey_auth_disabled",
    )
    report.check(
        "password_auth_disabled",
        (first_value(config, "passwordauthentication") or "").casefold() == "no",
        "password_auth_enabled",
    )
    kbd = first_value(config, "kbdinteractiveauthentication")
    if kbd is None:
        kbd = first_value(config, "challengeresponseauthentication")
    report.check("kbd_interactive_auth_disabled", (kbd or "yes").casefold() == "no", "kbd_interactive_auth_enabled")

    # Hostname-based Match/AllowUsers semantics cannot be evaluated from an address.
    report.check("usedns_disabled", (first_value(config, "usedns") or "").casefold() == "no", "usedns_enabled")

    # Root login is judged from the root connection context only, and only "no" is safe:
    # AuthorizedKeysCommand, TrustedUserCAKeys or principals can authorize root without
    # any local key file, so the key-based values are blocked rather than counted.
    root_login = (first_value(root_config, "permitrootlogin") or "").casefold()
    report.checks["root_login_safe"] = root_login == "no"
    if root_login in ("prohibit-password", "without-password"):
        report.reasons.add("root_key_login_possible")
    elif root_login != "no":
        report.reasons.add("root_login_permitted")

    report.check("sshd_port_22", "22" in tokens(config, "port"), "sshd_port_not_22")

    # A port-22 listener must be exactly laddr or the unspecified address of laddr's own
    # family; "::" is never assumed to accept IPv4.
    parsed = [parse_listen_address(line.split()[0]) for line in config.get("listenaddress", []) if line.split()]
    listeners = [item[0] for item in parsed if item is not None and item[1] == 22]
    wildcard = any(address.is_unspecified and address.version == listen.version for address in listeners)
    exact = any(address == listen for address in listeners)
    report.check("sshd_listens_on_tailnet", wildcard or exact, "sshd_not_listening_on_tailnet")
    if exact and not wildcard:
        report.warnings.add("sshd_bound_to_tailnet_address_only")

    check_access_filters(report, config, operator, client)
    command = first_value(config, "authorizedkeyscommand")
    if command is not None and command.casefold() != "none":
        report.warnings.add("authorized_keys_command_not_evaluated")

    scan = authorized_keys_state(authorized_keys_templates(config), operator)
    report.counts["operator_authorized_keys"] = scan.count
    report.check("authorized_keys_safe", not scan.unsafe, "authorized_keys_unsafe_permissions")
    report.check("operator_has_authorized_keys", scan.count > 0, "operator_authorized_keys_missing")
    if scan.options_lines:
        report.warnings.add("authorized_keys_options_not_evaluated")
    if scan.invalid_lines:
        report.warnings.add("authorized_keys_invalid_lines")

    active = False
    for unit in SSHD_UNITS:
        probe = run_command(["systemctl", "is-active", "--quiet", unit], timeout, "systemctl_unavailable")
        if probe.returncode == 0:
            active = True
            break
    report.check("sshd_active", active, "sshd_inactive")
    return report


# ------------------------------------------------------------------------ main


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    role, phase = hint_role_phase(argv)
    try:
        args = build_parser().parse_args(argv)
        role, phase = args.role, args.phase
        timeout = command_timeout()
        report = run_operator(args, timeout) if args.role == "operator" else run_host(args, timeout)
    except Abort as abort:
        print(render(role, phase, "error", {}, {abort.code}, set(), {}))
        return EXIT_CODES["error"]
    outcome = report.outcome()
    print(render(report.role, report.phase, outcome, report.checks, report.reasons, report.warnings, report.counts))
    return EXIT_CODES[outcome]


if __name__ == "__main__":
    sys.exit(main())
