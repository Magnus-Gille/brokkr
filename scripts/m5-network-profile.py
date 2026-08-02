#!/usr/bin/env python3
"""Render and safely transact the Brokkr M5 network-hardening profile.

Live topology stays in an owner-only configuration file.  The tracked example
contains only documentation addresses.  ``render`` never mutates the host;
``apply`` always arms a systemd rollback before changing configuration and can
only be finalized by a separate, probe-attested ``confirm`` invocation.
"""

from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
import fcntl
import hashlib
import ipaddress
import json
import os
import pwd
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable


class Refusal(RuntimeError):
    """A safe, operator-actionable refusal."""


IFACE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,32}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,48}$")
USER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]{0,31}$")
BOOLS = {"true": True, "false": False}
KNOWN_KEYS = {
    "operator_user",
    "management_interface",
    "ssh_port",
    "tailscale_transport",
    "samba_rule",
    "listener",
    "retain_netbios",
    "netbios_exception_reason",
    "ssh_agent_forwarding",
    "ssh_tcp_forwarding",
    "ssh_x11_forwarding",
    "ssh_exception_reason",
    "rollback_seconds",
}
NFT_TABLE = "brokkr_m5_tailnet"
NFT_CHAIN = "tailnet_prerouting"
SSH_POLICY_PATH = "ssh/sshd_config.d/00-brokkr-m5-network.conf"
NFT_POLICY_PATH = "nftables.d/brokkr-m5-tailnet.nft"
NFT_UNIT_PATH = "systemd/system/brokkr-m5-tailnet-filter.service"
NFT_UNIT = "brokkr-m5-tailnet-filter.service"


@dataclass(frozen=True)
class Transport:
    interface: str
    port: int


@dataclass(frozen=True)
class SambaRule:
    interface: str
    source: str


@dataclass(frozen=True)
class Listener:
    name: str
    proto: str
    port: int
    boundary: str


@dataclass
class Profile:
    operator_user: str = ""
    management_interface: str = ""
    ssh_port: int = 22
    transports: list[Transport] = field(default_factory=list)
    samba_rules: list[SambaRule] = field(default_factory=list)
    listeners: list[Listener] = field(default_factory=list)
    retain_netbios: bool = False
    netbios_exception_reason: str = ""
    ssh_agent_forwarding: bool = False
    ssh_tcp_forwarding: bool = False
    ssh_x11_forwarding: bool = False
    ssh_exception_reason: str = ""
    rollback_seconds: int = 300


def refuse(message: str) -> None:
    raise Refusal(message)


def strict_regular_owner_file(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        refuse("configuration file does not exist")
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        refuse("configuration must be a regular non-symlink file")
    if info.st_uid != os.geteuid():
        refuse("configuration must be owned by the invoking user")
    if stat.S_IMODE(info.st_mode) & 0o077:
        refuse("configuration must not grant group or other permissions")


def parse_bool(key: str, value: str) -> bool:
    if value not in BOOLS:
        refuse(f"{key} must be true or false")
    return BOOLS[value]


def parse_port(key: str, value: str) -> int:
    try:
        port = int(value)
    except ValueError:
        refuse(f"{key} must contain a numeric port")
    if not 1 <= port <= 65535:
        refuse(f"{key} port is outside 1..65535")
    return port


def validate_iface(value: str) -> str:
    if not IFACE_RE.fullmatch(value):
        refuse("interface names may contain only safe interface characters")
    return value


def validate_source(value: str) -> str:
    try:
        return str(ipaddress.ip_network(value, strict=False))
    except ValueError:
        refuse("Samba sources must be explicit IPv4 or IPv6 CIDR networks")


def split_exact(key: str, value: str, count: int) -> list[str]:
    parts = value.split("|")
    if len(parts) != count or any(not part for part in parts):
        refuse(f"{key} must have exactly {count} non-empty pipe-separated fields")
    return parts


def load_profile(path: Path) -> Profile:
    strict_regular_owner_file(path)
    values: dict[str, list[str]] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            refuse(f"configuration line {number} is not key=value")
        key, value = line.split("=", 1)
        if key not in KNOWN_KEYS:
            refuse(f"configuration line {number} uses unknown key {key!r}")
        if not value or value != value.strip():
            refuse(f"configuration line {number} has an empty or padded value")
        values.setdefault(key, []).append(value)

    singletons = KNOWN_KEYS - {"tailscale_transport", "samba_rule", "listener"}
    for key in singletons:
        if len(values.get(key, [])) > 1:
            refuse(f"{key} may appear only once")

    profile = Profile()
    profile.operator_user = first(values, "operator_user")
    if not USER_RE.fullmatch(profile.operator_user):
        refuse("operator_user is not a safe local account name")
    profile.management_interface = validate_iface(first(values, "management_interface"))
    if profile.management_interface != "tailscale0":
        refuse("the M5 management boundary must be the Tailscale interface tailscale0")
    profile.ssh_port = parse_port("ssh_port", first(values, "ssh_port", "22"))

    for value in values.get("tailscale_transport", []):
        interface, port = split_exact("tailscale_transport", value, 2)
        profile.transports.append(Transport(validate_iface(interface), parse_port("tailscale_transport", port)))
    if not profile.transports:
        refuse("at least one explicit Tailscale transport interface and observed UDP port is required")
    if any(item.interface == profile.management_interface for item in profile.transports):
        refuse("Tailscale transport must name a physical underlay, not tailscale0")

    for value in values.get("samba_rule", []):
        interface, source = split_exact("samba_rule", value, 2)
        profile.samba_rules.append(SambaRule(validate_iface(interface), validate_source(source)))
    if not profile.samba_rules:
        refuse("at least one exact Samba interface/source rule is required")

    for value in values.get("listener", []):
        name, proto, port, boundary = split_exact("listener", value, 4)
        if not NAME_RE.fullmatch(name):
            refuse("listener names may contain only safe name characters")
        if proto not in {"tcp", "udp"}:
            refuse("listener protocol must be tcp or udp")
        if boundary not in {"loopback", "management"}:
            refuse("listener boundary must be loopback or management")
        profile.listeners.append(Listener(name, proto, parse_port("listener", port), boundary))
    if not profile.listeners:
        refuse("every inference listener must be enumerated")
    listener_keys = [(item.proto, item.port) for item in profile.listeners]
    if len(listener_keys) != len(set(listener_keys)):
        refuse("each managed listener protocol/port pair must be unique")
    reserved_listener_ports = {
        ("tcp", profile.ssh_port),
        ("tcp", 445),
        ("tcp", 139),
        ("udp", 137),
        ("udp", 138),
    }
    if any(key in reserved_listener_ports for key in listener_keys):
        refuse("managed listeners may not collide with SSH, SMB, or NetBIOS service ports")

    for key in ("retain_netbios", "ssh_agent_forwarding", "ssh_tcp_forwarding", "ssh_x11_forwarding"):
        setattr(profile, key, parse_bool(key, first(values, key, "false")))
    profile.netbios_exception_reason = first(values, "netbios_exception_reason", "")
    profile.ssh_exception_reason = first(values, "ssh_exception_reason", "")
    if profile.retain_netbios and len(profile.netbios_exception_reason.strip()) < 12:
        refuse("retaining NetBIOS requires a specific reviewed exception reason")
    if (profile.ssh_agent_forwarding or profile.ssh_tcp_forwarding or profile.ssh_x11_forwarding) and len(profile.ssh_exception_reason.strip()) < 12:
        refuse("enabling SSH forwarding requires a specific reviewed exception reason")
    try:
        profile.rollback_seconds = int(first(values, "rollback_seconds", "300"))
    except ValueError:
        refuse("rollback_seconds must be numeric")
    if not 60 <= profile.rollback_seconds <= 1800:
        refuse("rollback_seconds must be between 60 and 1800")
    return profile


def first(values: dict[str, list[str]], key: str, default: str | None = None) -> str:
    found = values.get(key, [])
    if found:
        return found[0]
    if default is not None:
        return default
    refuse(f"{key} is required")
    raise AssertionError


def yesno(value: bool) -> str:
    return "yes" if value else "no"


def ssh_text(profile: Profile) -> str:
    return "\n".join(
        [
            "# Managed by Brokkr m5-network-profile.py; local edits are replaced.",
            "PermitRootLogin no",
            "PubkeyAuthentication yes",
            "PasswordAuthentication no",
            "KbdInteractiveAuthentication no",
            "ChallengeResponseAuthentication no",
            "AuthenticationMethods publickey",
            f"X11Forwarding {yesno(profile.ssh_x11_forwarding)}",
            f"AllowAgentForwarding {yesno(profile.ssh_agent_forwarding)}",
            f"AllowTcpForwarding {yesno(profile.ssh_tcp_forwarding)}",
            "AllowStreamLocalForwarding no",
            "GatewayPorts no",
            "PermitTunnel no",
            "PermitUserEnvironment no",
            "",
        ]
    )


def samba_text(profile: Profile) -> str:
    interfaces = sorted({rule.interface for rule in profile.samba_rules})
    sources = sorted({rule.source for rule in profile.samba_rules})
    ports = "445 139" if profile.retain_netbios else "445"
    return "\n".join(
        [
            "# Managed by Brokkr m5-network-profile.py; included from [global].",
            f"interfaces = lo {' '.join(interfaces)}",
            "bind interfaces only = yes",
            f"hosts allow = 127.0.0.1 ::1 {' '.join(sources)}",
            # Do not combine a catch-all hosts deny with hosts allow: Samba's
            # intersection semantics would also deny the explicitly allowed
            # clients.  A hosts-allow list alone denies everything else.
            "map to guest = Never",
            "guest ok = no",
            "restrict anonymous = 2",
            "server min protocol = SMB3_00",
            "smb encrypt = required",
            "usershare allow guests = no",
            "usershare max shares = 0",
            "load printers = no",
            "printing = bsd",
            "printcap name = /dev/null",
            "disable spoolss = yes",
            f"smb ports = {ports}",
            "",
        ]
    )


def allow_commands(profile: Profile) -> list[list[str]]:
    commands: list[list[str]] = []
    for transport in profile.transports:
        commands.append(["allow", "in", "on", transport.interface, "to", "any", "port", str(transport.port), "proto", "udp", "comment", "brokkr tailscale transport"])
    for rule in profile.samba_rules:
        if rule.interface == profile.management_interface:
            continue
        commands.append(["allow", "in", "on", rule.interface, "from", rule.source, "to", "any", "port", "445", "proto", "tcp", "comment", "brokkr samba"])
        if profile.retain_netbios:
            for proto, port in (("tcp", "139"), ("udp", "137"), ("udp", "138")):
                commands.append(["allow", "in", "on", rule.interface, "from", rule.source, "to", "any", "port", port, "proto", proto, "comment", "brokkr netbios exception"])
    unique: list[list[str]] = []
    seen: set[tuple[str, ...]] = set()
    for command in commands:
        key = tuple(command)
        if key not in seen:
            seen.add(key)
            unique.append(command)
    return unique


def nft_rule_fragments(profile: Profile) -> list[str]:
    interface = profile.management_interface
    rules = [
        f'iifname != "{interface}" accept comment "brokkr:non-tailnet:continue"',
        f'iifname "{interface}" ct state established,related accept comment "brokkr:tailnet:established"',
        f'iifname "{interface}" meta l4proto {{ icmp, ipv6-icmp }} accept comment "brokkr:tailnet:icmp"',
    ]
    for proto in ("tcp", "udp"):
        ports = {profile.ssh_port} if proto == "tcp" else set()
        ports.update(item.port for item in profile.listeners if item.boundary == "management" and item.proto == proto)
        if ports:
            rendered = ", ".join(str(port) for port in sorted(ports))
            rules.append(
                f'iifname "{interface}" {proto} dport {{ {rendered} }} accept comment "brokkr:tailnet:management:{proto}"'
            )
    for index, rule in enumerate(item for item in profile.samba_rules if item.interface == interface):
        family = "ip6" if ipaddress.ip_network(rule.source).version == 6 else "ip"
        rules.append(
            f'iifname "{interface}" {family} saddr {rule.source} tcp dport 445 accept comment "brokkr:tailnet:samba:{index}"'
        )
        if profile.retain_netbios:
            rules.extend(
                [
                    f'iifname "{interface}" {family} saddr {rule.source} tcp dport 139 accept comment "brokkr:tailnet:netbios:{index}:tcp"',
                    f'iifname "{interface}" {family} saddr {rule.source} udp dport {{ 137, 138 }} accept comment "brokkr:tailnet:netbios:{index}:udp"',
                ]
            )
    rules.append(f'iifname "{interface}" drop comment "brokkr:tailnet:default-drop"')
    return rules


def nft_text(profile: Profile) -> str:
    lines = [
        f"destroy table inet {NFT_TABLE}",
        f"add table inet {NFT_TABLE}",
        f'add chain inet {NFT_TABLE} {NFT_CHAIN} {{ type filter hook prerouting priority filter; policy accept; comment "brokkr managed tailnet gate"; }}',
    ]
    lines.extend(f"add rule inet {NFT_TABLE} {NFT_CHAIN} {rule}" for rule in nft_rule_fragments(profile))
    return "\n".join(lines) + "\n"


def nft_unit_text() -> str:
    return "\n".join(
        [
            "[Unit]",
            "Description=Brokkr M5 tailnet service-boundary filter",
            "After=local-fs.target",
            "Before=tailscaled.service network-online.target",
            "",
            "[Service]",
            "Type=oneshot",
            f"ExecStart=/usr/sbin/nft -f /etc/{NFT_POLICY_PATH}",
            f"ExecReload=/usr/sbin/nft -f /etc/{NFT_POLICY_PATH}",
            "RemainAfterExit=yes",
            "",
            "[Install]",
            "WantedBy=multi-user.target",
            "",
        ]
    )


def render(profile: Profile) -> str:
    lines = ["### sshd-drop-in", ssh_text(profile).rstrip(), "", "### samba-global-include", samba_text(profile).rstrip(), "", "### nft-tailnet-prerouting", nft_text(profile).rstrip(), "", "### ufw-physical-plan", "ufw --force reset", "ufw default deny incoming", "ufw default allow outgoing", "ufw default deny routed"]
    lines.extend("ufw " + shlex.join(command) for command in allow_commands(profile))
    lines.extend(["ufw --force enable", "", "### systemd-tailnet-filter", nft_unit_text().rstrip(), "", "### verifier-contract"])
    lines.extend(f"listener {item.name} {item.proto} {item.port} {item.boundary}" for item in profile.listeners)
    lines.extend(["tailscale-and-ufw-chains must coexist", "confirmation requires authorized, rejected, and Time Machine probes", ""])
    return "\n".join(lines)


def roots() -> tuple[Path, Path, Path]:
    return (
        Path(os.environ.get("BROKKR_NETWORK_ETC_ROOT", "/etc")),
        Path(os.environ.get("BROKKR_NETWORK_STATE_ROOT", "/var/lib/brokkr/m5-network")),
        Path(os.environ.get("BROKKR_NETWORK_RUN_ROOT", "/run")),
    )


def run(argv: Iterable[str], *, check: bool = True, input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(list(argv), text=True, input=input_text, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def require_commands(names: Iterable[str]) -> None:
    missing = [name for name in names if shutil.which(name) is None]
    if missing:
        refuse("required commands are missing: " + ", ".join(missing))


def effective_map(output: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in output.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if " = " in stripped:
            key, value = stripped.split(" = ", 1)
        elif " " in stripped:
            key, value = stripped.split(None, 1)
        else:
            continue
        result[key.lower()] = value.strip().lower()
    return result


def preflight(profile: Profile, *, mutation: bool) -> None:
    etc_root, state_root, run_root = roots()
    if mutation and etc_root == Path("/etc") and os.geteuid() != 0:
        refuse("apply, confirm, and rollback require root")
    if mutation and etc_root == Path("/etc"):
        script = Path(__file__)
        info = script.lstat()
        if script.is_symlink() or not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) & 0o022:
            refuse("live mutation requires a root-owned, non-writable, non-symlink script at a stable path")
    require_commands(["ufw", "sshd", "testparm", "systemctl", "systemd-run", "systemd-analyze", "ss", "ip", "iptables", "nft"])
    if run(["systemctl", "is-active", "tailscaled"], check=False).returncode != 0:
        refuse("tailscaled must be active before the network profile can be applied")
    if run(["sshd", "-t"], check=False).returncode != 0:
        refuse("current sshd configuration is invalid")
    if run(["testparm", "-s"], check=False).returncode != 0:
        refuse("current Samba configuration is invalid")
    if run(["ufw", "version"], check=False).returncode != 0:
        refuse("UFW is not usable")
    ufw_defaults = etc_root / "default/ufw"
    if not ufw_defaults.is_file() or ufw_defaults.is_symlink() or not re.search(
        r"(?m)^\s*IPV6\s*=\s*yes\s*$", ufw_defaults.read_text(encoding="utf-8")
    ):
        refuse("UFW IPv6 enforcement must be enabled before wildcard listeners can be protected")
    if run(["systemd-run", "--version"], check=False).returncode != 0:
        refuse("systemd-run is unavailable for the timed rollback")
    nft_check = run(["nft", "--check", "-f", "-"], check=False, input_text=nft_text(profile))
    if nft_check.returncode != 0:
        refuse("kernel/nftables cannot install the atomic pre-INPUT tailnet filter")
    tailscale_sockets = run(["ss", "-H", "-lnup"], check=False)
    if tailscale_sockets.returncode != 0:
        refuse("could not inspect the active Tailscale UDP listener")
    for port in {item.port for item in profile.transports}:
        if not any(
            re.search(rf"(?:\]|:){port}\s", line + " ") and "tailscaled" in line.lower()
            for line in tailscale_sockets.stdout.splitlines()
        ):
            refuse("configured Tailscale UDP transport port is not an active tailscaled listener")
    for interface in {profile.management_interface, *(item.interface for item in profile.transports), *(item.interface for item in profile.samba_rules)}:
        if run(["ip", "link", "show", "dev", interface], check=False).returncode != 0:
            refuse(f"required interface {interface!r} is absent")

    ssh_connection = os.environ.get("SSH_CONNECTION", "")
    client = os.environ.get("BROKKR_NETWORK_TEST_SSH_CLIENT", "")
    if ssh_connection:
        fields = ssh_connection.split()
        if len(fields) != 4:
            refuse("SSH_CONNECTION is malformed")
        client = fields[0]
    if mutation and not client and os.environ.get("BROKKR_NETWORK_CONSOLE", "") != "1":
        refuse("apply requires an SSH session over the management boundary or BROKKR_NETWORK_CONSOLE=1 at a physical console")
    if client:
        route = run(["ip", "route", "get", client], check=False)
        if route.returncode != 0 or not re.search(rf"\bdev\s+{re.escape(profile.management_interface)}\b", route.stdout):
            refuse("the invoking SSH client is not routed through the configured management interface")
        if mutation and etc_root == Path("/etc") and os.environ.get("SUDO_USER", "") != profile.operator_user:
            refuse("the management SSH session must belong to operator_user before sudo")

    ssh_effective = run(["sshd", "-T", "-C", f"user={profile.operator_user},host=localhost,addr=127.0.0.1"], check=False)
    if ssh_effective.returncode != 0:
        refuse("could not compute effective sshd policy for the operator")
    current = effective_map(ssh_effective.stdout)
    if current.get("pubkeyauthentication") != "yes":
        refuse("public-key authentication must already be enabled before hardening")
    if current.get("port") != str(profile.ssh_port):
        refuse("ssh_port does not match the current effective sshd listener port")
    if mutation and etc_root == Path("/etc"):
        try:
            operator = pwd.getpwnam(profile.operator_user)
        except KeyError:
            refuse("operator_user is not a local account")
        key_file = Path(operator.pw_dir) / ".ssh/authorized_keys"
        try:
            key_info = key_file.lstat()
        except FileNotFoundError:
            refuse("operator_user has no authorized_keys recovery path")
        if key_file.is_symlink() or not stat.S_ISREG(key_info.st_mode) or key_info.st_uid not in {0, operator.pw_uid} or stat.S_IMODE(key_info.st_mode) & 0o022:
            refuse("operator authorized_keys is not a safe regular owner-controlled file")
        usable_key = any(
            line.strip() and not line.lstrip().startswith("#") and ("ssh-" in line or "sk-ssh-" in line)
            for line in key_file.read_text(encoding="utf-8").splitlines()
        )
        if not usable_key:
            refuse("operator authorized_keys contains no usable public key")

    if mutation:
        ensure_private_state_directory(state_root)


def ensure_private_state_directory(path: Path) -> None:
    try:
        info = path.lstat()
    except FileNotFoundError:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.mkdir(mode=0o700)
        info = path.lstat()
    if path.is_symlink() or not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        refuse("transaction state directory must be a private invoking-user-owned non-symlink directory")


def insert_samba_include(smb_conf: Path, include_path: Path) -> None:
    text = smb_conf.read_text(encoding="utf-8")
    lines = text.splitlines()
    marker = f"include = {include_path}"
    lines = [line for line in lines if line.strip() != marker]
    global_indexes = [i for i, line in enumerate(lines) if line.strip().lower() == "[global]"]
    if len(global_indexes) != 1:
        refuse("smb.conf must contain exactly one [global] section")
    global_index = global_indexes[0]
    # Samba is last-definition-wins for many global parameters.  Put the
    # managed include at the end of [global], not immediately after its header,
    # so a weak legacy value later in that section cannot override it.
    next_section = next(
        (i for i in range(global_index + 1, len(lines)) if re.fullmatch(r"\s*\[[^]]+\]\s*", lines[i])),
        len(lines),
    )
    lines.insert(next_section, marker)
    smb_conf.write_text("\n".join(lines) + "\n", encoding="utf-8")


def file_manifest(paths: Iterable[Path], backup_dir: Path) -> dict[str, dict[str, object]]:
    manifest: dict[str, dict[str, object]] = {}
    files_dir = backup_dir / "files"
    files_dir.mkdir(parents=True)
    for index, path in enumerate(paths):
        entry: dict[str, object] = {"path": str(path), "existed": path.exists()}
        if path.exists():
            target = files_dir / str(index)
            shutil.copy2(path, target, follow_symlinks=False)
            entry["backup"] = str(target)
        manifest[str(index)] = entry
    return manifest


def service_state(name: str) -> dict[str, bool]:
    return {
        "enabled": run(["systemctl", "is-enabled", name], check=False).returncode == 0,
        "active": run(["systemctl", "is-active", name], check=False).returncode == 0,
    }


def current_session_material() -> str:
    ssh_connection = os.environ.get("SSH_CONNECTION", "")
    if ssh_connection:
        return "ssh:" + ssh_connection
    test_client = os.environ.get("BROKKR_NETWORK_TEST_SSH_CLIENT", "")
    if test_client:
        return "test-ssh:" + test_client
    if os.environ.get("BROKKR_NETWORK_CONSOLE", "") == "1":
        return "console"
    return "unknown"


def session_fingerprint(material: str, salt: str) -> str:
    return hashlib.sha256((salt + "\0" + material).encode("utf-8")).hexdigest()


def snapshot(profile_path: Path, tx_dir: Path, unit: str) -> dict[str, object]:
    etc_root, _, _ = roots()
    backup_dir = tx_dir / "backup"
    backup_dir.mkdir(parents=True)
    ufw_dir = etc_root / "ufw"
    if not ufw_dir.is_dir() or ufw_dir.is_symlink():
        refuse("UFW configuration directory is missing")
    shutil.copytree(ufw_dir, backup_dir / "ufw", symlinks=True)
    paths = [
        # OpenSSH uses the first obtained value for most keywords.  The owned
        # policy therefore sorts before vendor/cloud drop-ins rather than
        # relying on last-definition-wins semantics.
        etc_root / SSH_POLICY_PATH,
        etc_root / "samba/brokkr-network.conf",
        etc_root / "samba/smb.conf",
        etc_root / NFT_POLICY_PATH,
        etc_root / NFT_UNIT_PATH,
    ]
    for path in paths:
        if path.is_symlink():
            refuse("managed SSH/Samba paths must not be symlinks")
    active = run(["ufw", "status"], check=False).stdout.lower().startswith("status: active")
    session_salt = uuid.uuid4().hex
    session_material = current_session_material()
    prior_table = run(["nft", "list", "table", "inet", NFT_TABLE], check=False)
    if prior_table.returncode == 0:
        (backup_dir / "nft-table.nft").write_text(prior_table.stdout, encoding="utf-8")
        os.chmod(backup_dir / "nft-table.nft", 0o600)
    metadata: dict[str, object] = {
        "schema": 1,
        "created_at": int(time.time()),
        "unit": unit,
        "etc_root": str(etc_root),
        "ufw_was_active": active,
        "files": file_manifest(paths, backup_dir),
        "nmbd": service_state("nmbd.service"),
        "tailnet_filter": service_state(NFT_UNIT),
        "nft_table_existed": prior_table.returncode == 0,
        "apply_session_salt": session_salt,
        "apply_session_fingerprint": session_fingerprint(session_material, session_salt),
        "apply_via_console": session_material == "console",
        "status": "armed",
    }
    shutil.copy2(profile_path, tx_dir / "profile.conf")
    os.chmod(tx_dir / "profile.conf", 0o600)
    write_json(tx_dir / "transaction.json", metadata)
    return metadata


def write_json(path: Path, value: object) -> None:
    temporary = path.with_suffix(path.suffix + ".new")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def schedule_rollback(txid: str, seconds: int, unit: str) -> None:
    script = Path(__file__).resolve()
    result = run(
        [
            "systemd-run",
            f"--unit={unit}",
            f"--on-active={seconds}s",
            "--property=Type=oneshot",
            str(script),
            "rollback",
            "--transaction",
            txid,
            "--timer-fired",
        ],
        check=False,
    )
    if result.returncode != 0:
        refuse("could not arm the timed rollback")


def install_candidates(profile: Profile) -> None:
    etc_root, _, _ = roots()
    ssh_path = etc_root / SSH_POLICY_PATH
    samba_path = etc_root / "samba/brokkr-network.conf"
    smb_conf = etc_root / "samba/smb.conf"
    nft_path = etc_root / NFT_POLICY_PATH
    unit_path = etc_root / NFT_UNIT_PATH
    ssh_path.parent.mkdir(parents=True, exist_ok=True)
    samba_path.parent.mkdir(parents=True, exist_ok=True)
    nft_path.parent.mkdir(parents=True, exist_ok=True)
    unit_path.parent.mkdir(parents=True, exist_ok=True)
    ssh_path.write_text(ssh_text(profile), encoding="utf-8")
    samba_path.write_text(samba_text(profile), encoding="utf-8")
    nft_path.write_text(nft_text(profile), encoding="utf-8")
    unit_path.write_text(nft_unit_text(), encoding="utf-8")
    os.chmod(ssh_path, 0o644)
    os.chmod(samba_path, 0o644)
    os.chmod(nft_path, 0o600)
    os.chmod(unit_path, 0o644)
    insert_samba_include(smb_conf, samba_path)
    if run(["sshd", "-t"], check=False).returncode != 0:
        refuse("candidate sshd configuration failed validation")
    if run(["testparm", "-s"], check=False).returncode != 0:
        refuse("candidate Samba configuration failed validation")
    if run(["nft", "--check", "-f", str(nft_path)], check=False).returncode != 0:
        refuse("candidate tailnet nftables policy failed validation")
    if run(["systemd-analyze", "verify", str(unit_path)], check=False).returncode != 0:
        refuse("candidate tailnet-filter unit failed validation")


def apply_tailnet_filter() -> None:
    etc_root, _, _ = roots()
    nft_path = etc_root / NFT_POLICY_PATH
    if run(["nft", "-f", str(nft_path)], check=False).returncode != 0:
        refuse("atomic tailnet pre-INPUT filter apply failed")
    if run(["systemctl", "daemon-reload"], check=False).returncode != 0:
        refuse("systemd could not load the persistent tailnet-filter unit")
    if run(["systemctl", "enable", "--now", NFT_UNIT], check=False).returncode != 0:
        refuse("persistent tailnet-filter unit could not be enabled")


def apply_ufw(profile: Profile) -> None:
    commands = [
        ["ufw", "--force", "reset"],
        ["ufw", "default", "deny", "incoming"],
        ["ufw", "default", "allow", "outgoing"],
        ["ufw", "default", "deny", "routed"],
    ]
    commands.extend([["ufw", *command] for command in allow_commands(profile)])
    commands.append(["ufw", "--force", "enable"])
    for command in commands:
        result = run(command, check=False)
        if result.returncode != 0:
            refuse("UFW rejected the rendered default-deny profile")


def ssh_expected(profile: Profile) -> dict[str, str]:
    return {
        "port": str(profile.ssh_port),
        "permitrootlogin": "no",
        "pubkeyauthentication": "yes",
        "passwordauthentication": "no",
        "kbdinteractiveauthentication": "no",
        "authenticationmethods": "publickey",
        "x11forwarding": yesno(profile.ssh_x11_forwarding),
        "allowagentforwarding": yesno(profile.ssh_agent_forwarding),
        "allowtcpforwarding": yesno(profile.ssh_tcp_forwarding),
        "allowstreamlocalforwarding": "no",
        "gatewayports": "no",
        "permittunnel": "no",
        "permituserenvironment": "no",
    }


def normalize_nft(value: str) -> str:
    value = " ".join(value.split())
    value = re.sub(r"\s*,\s*", ",", value)
    value = re.sub(r"\{\s*", "{ ", value)
    value = re.sub(r"\s*\}", " }", value)
    return value


def verify_tailnet_filter(profile: Profile) -> None:
    listed_json = run(["nft", "-j", "-nn", "list", "chain", "inet", NFT_TABLE, NFT_CHAIN], check=False)
    if listed_json.returncode != 0:
        refuse("post-apply verifier: pre-INPUT tailnet filter chain is absent")
    try:
        nft_payload = json.loads(listed_json.stdout)
        nft_items = nft_payload["nftables"]
    except (json.JSONDecodeError, KeyError, TypeError):
        refuse("post-apply verifier: nftables did not return a structured chain description")
    expected = [normalize_nft(fragment) for fragment in nft_rule_fragments(profile)]
    rule_objects = [
        item["rule"]
        for item in nft_items
        if isinstance(item, dict)
        and isinstance(item.get("rule"), dict)
        and item["rule"].get("family") == "inet"
        and item["rule"].get("table") == NFT_TABLE
        and item["rule"].get("chain") == NFT_CHAIN
    ]
    if len(rule_objects) != len(expected):
        refuse("post-apply verifier: tailnet gate contains an unexpected or missing rule")

    listed = run(["nft", "-nn", "list", "chain", "inet", NFT_TABLE, NFT_CHAIN], check=False)
    if listed.returncode != 0:
        refuse("post-apply verifier: pre-INPUT tailnet filter chain is absent")
    normalized = normalize_nft(listed.stdout)
    if "type filter hook prerouting priority filter; policy accept;" not in normalized:
        refuse("post-apply verifier: tailnet gate is not a prerouting filter chain")
    for fragment in expected:
        if normalized.count(fragment) != 1:
            refuse("post-apply verifier: tailnet gate differs from the exact rendered service boundary")
    if normalized.count('comment "brokkr:') != len(expected):
        refuse("post-apply verifier: tailnet gate contains an unexpected managed rule")
    if run(["systemctl", "is-active", NFT_UNIT], check=False).returncode != 0:
        refuse("post-apply verifier: tailnet filter persistence unit is not active")
    if run(["systemctl", "is-enabled", NFT_UNIT], check=False).returncode != 0:
        refuse("post-apply verifier: tailnet filter persistence unit is not enabled")


def verify(profile: Profile) -> None:
    # Tailscale netfilter mode=on accepts tailscale0 in ts-input before UFW's
    # INPUT chains.  The owned nftables prerouting gate is therefore the actual
    # tailnet service-boundary enforcement; UFW below protects physical paths.
    verify_tailnet_filter(profile)
    status = run(["ufw", "status", "verbose"], check=False)
    lower = status.stdout.lower()
    if status.returncode != 0 or "status: active" not in lower:
        refuse("post-apply verifier: UFW is not active")
    compact = " ".join(lower.split())
    for phrase in ("default: deny (incoming)", "allow (outgoing)", "deny (routed)"):
        if phrase not in compact:
            refuse("post-apply verifier: UFW defaults are not deny-inbound/deny-routed/allow-outbound")

    added = run(["ufw", "show", "added"], check=False)
    if added.returncode != 0:
        refuse("post-apply verifier: could not inspect UFW user rules")
    actual_rules: list[tuple[str, ...]] = []
    for line in added.stdout.splitlines():
        if not line.startswith("ufw "):
            continue
        try:
            tokens = shlex.split(line)
        except ValueError:
            refuse("post-apply verifier: UFW emitted an unparsable user rule")
        if len(tokens) <= 1:
            refuse("post-apply verifier: UFW emitted an empty user command")
        actual_rules.append(tuple(tokens[1:]))
    expected_rules = Counter(tuple(command) for command in allow_commands(profile))
    if Counter(actual_rules) != expected_rules:
        refuse("post-apply verifier: active UFW allowances differ from the exact rendered profile")

    sshd = run(["sshd", "-T", "-C", f"user={profile.operator_user},host=localhost,addr=127.0.0.1"], check=False)
    effective = effective_map(sshd.stdout)
    for key, expected in ssh_expected(profile).items():
        if effective.get(key) != expected:
            refuse(f"post-apply verifier: effective sshd {key} is not {expected}")

    samba = run(["testparm", "-s"], check=False)
    smb = effective_map(samba.stdout)
    expected_smb = {
        "bind interfaces only": "yes",
        "map to guest": "never",
        "guest ok": "no",
        "restrict anonymous": "2",
        "server min protocol": "smb3_00",
        "smb encrypt": "required",
        "usershare allow guests": "no",
        "usershare max shares": "0",
        "load printers": "no",
        "disable spoolss": "yes",
        "smb ports": "445 139" if profile.retain_netbios else "445",
    }
    for key, expected in expected_smb.items():
        if smb.get(key) != expected:
            refuse(f"post-apply verifier: effective Samba {key} is not {expected}")
    expected_interfaces = {"lo", *(rule.interface for rule in profile.samba_rules)}
    if set(smb.get("interfaces", "").split()) != expected_interfaces:
        refuse("post-apply verifier: effective Samba interfaces differ from the exact profile")
    expected_sources = {"127.0.0.1", "::1", *(rule.source for rule in profile.samba_rules)}
    if set(smb.get("hosts allow", "").split()) != expected_sources:
        refuse("post-apply verifier: effective Samba hosts allow differs from the exact profile")
    if re.search(r"(?mi)^\s*(?:guest ok|public)\s*=\s*yes\s*$", samba.stdout):
        refuse("post-apply verifier: an effective Samba share permits guest access")
    if not profile.retain_netbios:
        if run(["systemctl", "is-active", "nmbd.service"], check=False).returncode == 0:
            refuse("post-apply verifier: nmbd remains active without an exception")
        if run(["systemctl", "is-enabled", "nmbd.service"], check=False).returncode == 0:
            refuse("post-apply verifier: nmbd remains enabled without an exception")

    tcp = run(["ss", "-H", "-lnt"], check=False).stdout
    udp = run(["ss", "-H", "-lnu"], check=False).stdout
    for listener in profile.listeners:
        listing = tcp if listener.proto == "tcp" else udp
        matches = [line for line in listing.splitlines() if re.search(rf"(?:\]|:){listener.port}\s", line + " ")]
        if not matches:
            refuse(f"post-apply verifier: managed listener {listener.name} is absent")
        if listener.boundary == "loopback":
            for line in matches:
                if not any(value in line for value in ("127.0.0.1:", "[::1]:", "::1:")):
                    refuse(f"post-apply verifier: {listener.name} is not loopback-bound")

    nft = run(["nft", "list", "ruleset"], check=False)
    iptables = run(["iptables", "-w", "-S", "INPUT"], check=False)
    joined = (nft.stdout + "\n" + iptables.stdout).lower()
    if "tailscale" not in joined and "ts-input" not in joined:
        refuse("post-apply verifier: Tailscale firewall chains disappeared")
    if "ufw" not in joined:
        refuse("post-apply verifier: UFW firewall chains are absent")


@contextmanager
def mutation_lock(*, blocking: bool = False) -> Iterable[None]:
    _, _, run_root = roots()
    if not run_root.is_dir() or run_root.is_symlink():
        refuse("runtime directory is missing or unsafe")
    lock_path = run_root / "brokkr-m5-network.lock"
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(lock_path, flags, 0o600)
    except OSError:
        refuse("network transaction lock is unsafe or unavailable")
    with os.fdopen(descriptor, "a+", encoding="utf-8") as lock:
        info = os.fstat(lock.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
            refuse("network transaction lock must be private and invoking-user-owned")
        try:
            operation = fcntl.LOCK_EX if blocking else fcntl.LOCK_EX | fcntl.LOCK_NB
            fcntl.flock(lock, operation)
        except BlockingIOError:
            refuse("another M5 network transaction is in progress")
        yield


def refuse_existing_armed_transaction(state_root: Path) -> None:
    transaction_root = state_root / "transactions"
    if not transaction_root.is_dir():
        return
    for candidate in transaction_root.iterdir():
        metadata_path = candidate / "transaction.json"
        if not candidate.is_dir() or candidate.is_symlink() or not metadata_path.is_file():
            continue
        try:
            status = json.loads(metadata_path.read_text(encoding="utf-8")).get("status")
        except (OSError, json.JSONDecodeError):
            refuse("an existing transaction receipt is unreadable")
        if status not in {"confirmed", "rolled_back", "aborted_before_mutation"}:
            refuse("an earlier network transaction is still armed and must be confirmed or rolled back")


def transaction_dir(txid: str) -> Path:
    if not re.fullmatch(r"[0-9a-f]{16}", txid):
        refuse("invalid transaction identifier")
    _, state_root, _ = roots()
    path = state_root / "transactions" / txid
    if not path.is_dir() or path.is_symlink():
        refuse("transaction does not exist")
    return path


def command_apply(args: argparse.Namespace) -> None:
    profile_path = Path(args.config)
    profile = load_profile(profile_path)
    preflight(profile, mutation=True)
    _, state_root, _ = roots()
    with mutation_lock():
        refuse_existing_armed_transaction(state_root)
        txid = uuid.uuid4().hex[:16]
        tx_dir = state_root / "transactions" / txid
        tx_dir.mkdir(parents=True, mode=0o700)
        unit = f"brokkr-m5-network-rollback-{txid}"
        snapshot(profile_path, tx_dir, unit)
        try:
            schedule_rollback(txid, profile.rollback_seconds, unit)
        except Exception:
            metadata = json.loads((tx_dir / "transaction.json").read_text(encoding="utf-8"))
            metadata["status"] = "aborted_before_mutation"
            metadata["aborted_at"] = int(time.time())
            write_json(tx_dir / "transaction.json", metadata)
            raise
        try:
            install_candidates(profile)
            run(["systemctl", "reload", "ssh.service"], check=True)
            run(["systemctl", "reload", "smbd.service"], check=True)
            if profile.retain_netbios:
                run(["systemctl", "enable", "--now", "nmbd.service"], check=True)
            else:
                run(["systemctl", "disable", "--now", "nmbd.service"], check=False)
            apply_tailnet_filter()
            apply_ufw(profile)
            verify(profile)
        except Exception:
            restore_transaction(tx_dir, stop_timer=True)
            raise
        metadata = json.loads((tx_dir / "transaction.json").read_text(encoding="utf-8"))
        metadata["status"] = "awaiting_external_confirmation"
        write_json(tx_dir / "transaction.json", metadata)
        print(f"transaction={txid}")
        print(f"rollback_armed_seconds={profile.rollback_seconds}")
        print("next=run authorized, rejected-path, and Time Machine probes, then confirm explicitly")


def restore_file(entry: dict[str, object]) -> None:
    path = Path(str(entry["path"]))
    if bool(entry["existed"]):
        source = Path(str(entry["backup"]))
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, path, follow_symlinks=False)
    elif path.exists() or path.is_symlink():
        path.unlink()


def restore_service(name: str, wanted: dict[str, object]) -> list[str]:
    failures: list[str] = []
    if bool(wanted.get("enabled")):
        if run(["systemctl", "enable", name], check=False).returncode != 0:
            failures.append(f"enable {name}")
    else:
        if run(["systemctl", "disable", name], check=False).returncode != 0:
            failures.append(f"disable {name}")
    if bool(wanted.get("active")):
        if run(["systemctl", "start", name], check=False).returncode != 0:
            failures.append(f"start {name}")
    else:
        if run(["systemctl", "stop", name], check=False).returncode != 0:
            failures.append(f"stop {name}")
    if (run(["systemctl", "is-enabled", name], check=False).returncode == 0) != bool(wanted.get("enabled")):
        failures.append(f"verify enabled {name}")
    if (run(["systemctl", "is-active", name], check=False).returncode == 0) != bool(wanted.get("active")):
        failures.append(f"verify active {name}")
    return failures


def restore_transaction(tx_dir: Path, *, stop_timer: bool) -> None:
    metadata = json.loads((tx_dir / "transaction.json").read_text(encoding="utf-8"))
    unit = str(metadata["unit"])
    failures: list[str] = []
    if stop_timer:
        if run(["systemctl", "stop", unit + ".timer"], check=False).returncode != 0:
            failures.append("stop rollback timer")
        # The transient service may not have run yet; stopping an absent or
        # inactive service is advisory after its timer has been stopped.
        run(["systemctl", "stop", unit + ".service"], check=False)
    etc_root = Path(str(metadata["etc_root"]))
    if etc_root != roots()[0]:
        refuse("transaction root no longer matches the active host root")
    ufw_current = etc_root / "ufw"
    ufw_backup = tx_dir / "backup/ufw"
    if not ufw_backup.is_dir() or ufw_backup.is_symlink():
        refuse("rollback UFW snapshot is missing or unsafe")
    if ufw_current.is_symlink():
        refuse("rollback target UFW directory became a symlink")
    if ufw_current.exists():
        shutil.rmtree(ufw_current)
    shutil.copytree(ufw_backup, ufw_current, symlinks=True)
    # Disable the candidate-owned unit while its definition is still present.
    # Otherwise a first-install rollback can remove the unit file before
    # systemd has a chance to remove its enablement symlink cleanly.
    if run(["systemctl", "disable", "--now", NFT_UNIT], check=False).returncode != 0:
        failures.append("disable candidate tailnet filter service")
    for entry in dict(metadata["files"]).values():
        restore_file(dict(entry))
    if run(["nft", "destroy", "table", "inet", NFT_TABLE], check=False).returncode != 0:
        failures.append("remove candidate tailnet table")
    if bool(metadata.get("nft_table_existed")):
        nft_backup = tx_dir / "backup/nft-table.nft"
        if not nft_backup.is_file() or nft_backup.is_symlink() or run(["nft", "-f", str(nft_backup)], check=False).returncode != 0:
            failures.append("restore prior tailnet table")
    if run(["systemctl", "daemon-reload"], check=False).returncode != 0:
        failures.append("systemd daemon-reload")
    failures.extend(restore_service(NFT_UNIT, dict(metadata["tailnet_filter"])))
    if run(["sshd", "-t"], check=False).returncode != 0:
        failures.append("validate restored sshd")
    if run(["testparm", "-s"], check=False).returncode != 0:
        failures.append("validate restored Samba")
    if run(["systemctl", "reload", "ssh.service"], check=False).returncode != 0:
        failures.append("reload restored sshd")
    if run(["systemctl", "reload", "smbd.service"], check=False).returncode != 0:
        failures.append("reload restored smbd")
    failures.extend(restore_service("nmbd.service", dict(metadata["nmbd"])))
    if bool(metadata["ufw_was_active"]):
        if run(["ufw", "--force", "enable"], check=False).returncode != 0:
            failures.append("enable restored UFW")
        if run(["ufw", "--force", "reload"], check=False).returncode != 0:
            failures.append("reload restored UFW")
    else:
        if run(["ufw", "--force", "disable"], check=False).returncode != 0:
            failures.append("disable restored UFW")
    restored_active = run(["ufw", "status"], check=False).stdout.lower().startswith("status: active")
    if restored_active != bool(metadata["ufw_was_active"]):
        failures.append("verify restored UFW state")
    if failures:
        metadata["status"] = "rollback_failed"
        metadata["rollback_failed_at"] = int(time.time())
        metadata["rollback_failures"] = failures
        write_json(tx_dir / "transaction.json", metadata)
        refuse("rollback was incomplete; transaction receipt preserves exact local failures")
    metadata["status"] = "rolled_back"
    metadata["rolled_back_at"] = int(time.time())
    write_json(tx_dir / "transaction.json", metadata)


def command_rollback(args: argparse.Namespace) -> None:
    tx_dir = transaction_dir(args.transaction)
    with mutation_lock(blocking=args.timer_fired):
        restore_transaction(tx_dir, stop_timer=not args.timer_fired)
    print(f"rolled_back={args.transaction}")


def command_confirm(args: argparse.Namespace) -> None:
    if not (args.authorized_probes_pass and args.disallowed_probes_rejected and args.timemachine_pass):
        refuse("confirmation requires all three external probe attestations")
    tx_dir = transaction_dir(args.transaction)
    with mutation_lock():
        metadata = json.loads((tx_dir / "transaction.json").read_text(encoding="utf-8"))
        if metadata.get("status") != "awaiting_external_confirmation":
            refuse("only an awaiting transaction can be confirmed")
        profile = load_profile(tx_dir / "profile.conf")
        material = current_session_material()
        if material == "unknown":
            refuse("confirmation requires a distinct management SSH session or an explicit physical console")
        applying_fingerprint = str(metadata.get("apply_session_fingerprint", ""))
        confirming_fingerprint = session_fingerprint(material, str(metadata.get("apply_session_salt", "")))
        if material != "console" and confirming_fingerprint == applying_fingerprint:
            refuse("the applying SSH session cannot confirm its own network transaction")
        unit = str(metadata["unit"])
        if run(["systemctl", "stop", unit + ".timer"], check=False).returncode != 0:
            refuse("could not disarm the rollback timer; transaction remains unconfirmed")
        if run(["systemctl", "is-active", unit + ".timer"], check=False).returncode == 0:
            refuse("rollback timer remains active; transaction remains unconfirmed")
        run(["systemctl", "reset-failed", unit + ".service"], check=False)
        try:
            preflight(profile, mutation=True)
            verify(profile)
        except Exception:
            restore_transaction(tx_dir, stop_timer=False)
            raise
        metadata["status"] = "confirmed"
        metadata["confirmed_at"] = int(time.time())
        metadata["external_probes"] = {
            "authorized_paths": "pass",
            "disallowed_paths": "rejected",
            "timemachine": "pass",
        }
        write_json(tx_dir / "transaction.json", metadata)
    print(f"confirmed={args.transaction}")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    sub = root.add_subparsers(dest="command", required=True)
    for name in ("render", "preflight", "verify", "apply"):
        item = sub.add_parser(name)
        item.add_argument("--config", required=True)
    confirm = sub.add_parser("confirm")
    confirm.add_argument("--transaction", required=True)
    confirm.add_argument("--authorized-probes-pass", action="store_true")
    confirm.add_argument("--disallowed-probes-rejected", action="store_true")
    confirm.add_argument("--timemachine-pass", action="store_true")
    rollback = sub.add_parser("rollback")
    rollback.add_argument("--transaction", required=True)
    rollback.add_argument("--timer-fired", action="store_true", help=argparse.SUPPRESS)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.command == "render":
        print(render(load_profile(Path(args.config))), end="")
    elif args.command == "preflight":
        profile = load_profile(Path(args.config))
        preflight(profile, mutation=False)
        print("preflight=pass")
    elif args.command == "verify":
        profile = load_profile(Path(args.config))
        verify(profile)
        print("verify=pass")
    elif args.command == "apply":
        command_apply(args)
    elif args.command == "confirm":
        command_confirm(args)
    elif args.command == "rollback":
        command_rollback(args)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Refusal as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        raise SystemExit(2)
    except subprocess.CalledProcessError as error:
        print(f"REFUSED: command failed safely: {shlex.join(error.cmd)}", file=sys.stderr)
        raise SystemExit(2)
