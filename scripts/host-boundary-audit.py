#!/usr/bin/env python3
"""Read-only, content-blind audit of a host's management and share boundaries.

Run on the host itself (root recommended: `sshd -T` and `ss -p` need it). The audit changes nothing,
opens no network connection and reads no credential, key, share path or configuration body. It runs only:

  ss -H -ltnp | -ltn, ss -H -lunp | -lun   listening TCP and UDP sockets
  sshd -T [-C ...]           effective OpenSSH configuration, globally and per connection context
  testparm -s                effective Samba global parameters (only when installed)
  systemctl is-active / is-enabled   for a fixed list of unit names

Why per connection context: a global `sshd -T` ignores `Match` blocks, so it can say
PasswordAuthentication=yes while every real peer is forced to keys, or the reverse. Each context
evaluates sshd for that user and source address as sshd itself would. A built-in "stranger" context
(a reserved TEST-NET source and an unprivileged name) shows what an unmatched peer gets. `sshd -T -C`
dumps keywords only: it does NOT prove that AllowUsers/AllowGroups/DenyUsers admit a connection, so
admission still needs the runbook's real-login proofs.

Contexts are `USER@ADDRESS`. Prefer --context-file (one per line, owner-only file) so accounts and
addresses do not appear in argv, which sudo logs and other local processes can read.

Output is one line of JSON and nothing on stderr: booleans, integer counts, port numbers, and short
snake_case codes. Never addresses, user names, share names, paths, key material or raw command output.
A finding is an observation about bind/configuration, not proof of reachability or of a successful login.

Exit status: 0 report written, 3 findings present with --fail-on-findings, 1 error or bad usage.
"""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import re
import shutil
import stat
import subprocess
import sys

SCHEMA_VERSION = "v1"
OBSERVED_TCP = (111, 139, 445, 5900)
OBSERVED_UDP = (111, 137, 138)
STRANGER_USER = "nobody"
STRANGER_ADDR = "192.0.2.1"  # RFC 5737 TEST-NET-1: never matches an owner Match Address rule
CONTEXT = re.compile(r"([a-z_][a-z0-9_-]{0,31})@([0-9A-Fa-f:.]{2,45})")
ROLE = re.compile(r"[a-z][a-z0-9-]{0,31}")
PROCESS_CLASSES = {
    "sshd": "sshd", "smbd": "smbd", "nmbd": "nmbd", "rpcbind": "rpcbind", "tailscaled": "tailscaled",
    "wayvnc": "vnc", "Xvnc": "vnc", "Xtigervnc": "vnc", "x11vnc": "vnc", "x0vncserver": "vnc",
    "vncserver": "vnc", "vino-server": "vnc", "vncserver-x11-": "vnc", "vncserver-virt": "vnc",
}
UNITS = ("ssh.service", "ssh.socket", "sshd.service", "smbd.service", "nmbd.service", "rpcbind.service", "rpcbind.socket")
ACTIVE_STATES = {"active", "inactive", "failed", "activating", "deactivating", "unknown"}
ENABLED_STATES = {"enabled", "disabled", "static", "masked", "indirect", "alias", "generated", "unknown"}
ROOT_LOGIN_VALUES = {"no", "yes", "prohibit-password", "without-password", "forced-commands-only"}
SMB_ENCRYPT_VALUES = {"default", "desired", "required", "off", "if_required", "mandatory", "auto"}
SMB_PROTOCOLS = {"nt1", "smb2", "smb2_02", "smb2_10", "smb2_22", "smb2_24", "smb3", "smb3_00", "smb3_02", "smb3_10", "smb3_11", "core", "lanman1", "lanman2", "coreplus"}
SBIN = "/usr/sbin:/sbin:/usr/local/sbin"


class AuditError(Exception):
    pass


class QuietParser(argparse.ArgumentParser):
    def error(self, message: str):  # keep stderr empty and the exit code distinct from "findings"
        print(json.dumps({"schema": SCHEMA_VERSION, "result": "error", "code": "usage"}, sort_keys=True))
        sys.exit(1)


def tool(name: str) -> str | None:
    return shutil.which(name, path=os.environ.get("PATH", "") + os.pathsep + SBIN)


def run(argv: list[str], timeout: int) -> tuple[int, str]:
    path = tool(argv[0])
    if path is None:
        raise AuditError("command_failed")
    try:
        done = subprocess.run([path, *argv[1:]], capture_output=True, text=True, errors="replace", timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AuditError("command_failed") from exc
    return done.returncode, done.stdout


def scope_of(host: str) -> str:
    host = host.split("%", 1)[0].strip("[]")
    if host in ("*", "", "::", "0.0.0.0"):
        return "wildcard"
    try:
        return "loopback" if ipaddress.ip_address(host).is_loopback else "specific"
    except ValueError:
        return "specific"


def parse_listeners(text: str, observed: tuple[int, ...]) -> dict:
    ports: dict[int, dict] = {}
    wildcard_other = 0
    vnc_exposed = 0
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 4 or fields[0] not in ("LISTEN", "UNCONN"):
            continue
        host, _, port_text = fields[3].rpartition(":")
        if not port_text.isdigit():
            continue
        port, scope = int(port_text), scope_of(host)
        proc = re.search(r'\(\("([^"]+)"', line)
        klass = "unknown" if not proc else next((v for k, v in PROCESS_CLASSES.items() if proc.group(1).startswith(k)), "other")
        if klass == "vnc" and scope != "loopback":
            vnc_exposed += 1
        if port not in observed:
            if scope == "wildcard":
                wildcard_other += 1
            continue
        entry = ports.setdefault(port, {"scopes": set(), "process": "unknown"})
        entry["scopes"].add(scope)
        if proc:
            entry["process"] = klass
    return {
        "ports": {p: {"scopes": sorted(e["scopes"]), "process": e["process"]} for p, e in ports.items()},
        "wildcard_other_count": wildcard_other,
        "vnc_exposed_count": vnc_exposed,
    }


def parse_keyed(text: str) -> dict[str, list[str]]:
    config: dict[str, list[str]] = {}
    for line in text.splitlines():
        key, _, value = line.strip().partition(" ")
        if key:
            config.setdefault(key.lower(), []).append(value.strip())
    return config


def sshd_view(config: dict[str, list[str]]) -> dict:
    def one(key: str) -> str | None:
        values = {v.lower() for v in config.get(key, [])}
        return next(iter(values)) if len(values) == 1 else None

    root = one("permitrootlogin")
    tcp = one("allowtcpforwarding")
    permitopen = [v for v in config.get("permitopen", []) if v.lower() != "any"]
    others_on = (
        one("allowagentforwarding") != "no" or one("x11forwarding") != "no"
        or one("allowstreamlocalforwarding") != "no" or one("permittunnel") != "no"
        or one("gatewayports") != "no"
    )
    tcp_open = tcp != "no" and not (tcp == "local" and permitopen)
    disabled = one("disableforwarding") == "yes"
    return {
        "password_auth": one("passwordauthentication") != "no",
        "kbd_interactive": one("kbdinteractiveauthentication") != "no",
        "pubkey_auth": one("pubkeyauthentication") == "yes",
        "root_login": root if root in ROOT_LOGIN_VALUES else "unknown",
        "any_forwarding": (others_on or tcp_open) and not disabled,
        "forwarding_restricted_tunnel": tcp == "local" and bool(permitopen) and not others_on,
        "max_auth_tries_low": (int(one("maxauthtries") or "6") < 5) if (one("maxauthtries") or "6").isdigit() else False,
        "listen_scoped": bool(config.get("listenaddress")) and all(
            scope_of(v.rpartition(":")[0] or v) != "wildcard" for v in config["listenaddress"]
        ),
        "allow_filter_present": any(config.get(k) for k in ("allowusers", "allowgroups", "denyusers", "denygroups")),
    }


def audit_ssh(contexts: list[str], timeout: int) -> dict | None:
    if tool("sshd") is None:
        return None
    rc, out = run(["sshd", "-T"], timeout)
    if rc != 0:
        raise AuditError("sshd_config_unreadable")
    base = parse_keyed(out)
    global_view = sshd_view(base)
    ports = sorted({int(p) for p in base.get("port", ["22"]) if p.isdigit()}) or [22]
    report: dict = {"global": global_view, "ports": ports, "contexts": {}}
    labelled = [(f"context_{i + 1}", c) for i, c in enumerate(contexts)]
    labelled.append(("stranger", f"{STRANGER_USER}@{STRANGER_ADDR}"))
    for label, ctx in labelled:
        user, addr = ctx.split("@", 1)
        rc, out = run(["sshd", "-T", "-C", f"user={user},host={addr},addr={addr},lport={ports[0]}"], timeout)
        if rc != 0:
            raise AuditError("sshd_context_unreadable")
        view = sshd_view(parse_keyed(out))
        view["differs_from_global"] = any(view[k] != global_view[k] for k in global_view)
        report["contexts"][label] = view
    return report


def audit_samba(timeout: int) -> dict | None:
    if tool("testparm") is None:
        return None
    rc, out = run(["testparm", "-s", "--suppress-prompt"], timeout)
    if rc != 0:
        raise AuditError("samba_config_unreadable")
    section, glob, guest_share = "", {}, False
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].lower()
        elif "=" in line:
            key, _, value = line.partition("=")
            key, value = " ".join(key.lower().split()), value.strip().lower()
            if section == "global":
                glob[key] = value
            elif key in ("guest ok", "public") and value in ("yes", "true", "1"):
                guest_share = True
    encrypt = glob.get("server smb encrypt", glob.get("smb encrypt", "default"))
    proto = glob.get("server min protocol")
    return {
        "bind_interfaces_only": glob.get("bind interfaces only") in ("yes", "true", "1"),
        "interfaces_set": "interfaces" in glob,
        "hosts_allow_set": "hosts allow" in glob,
        "guest_map_enabled": glob.get("map to guest", "never") != "never",
        "guest_share_present": guest_share,
        "encrypt": encrypt if encrypt in SMB_ENCRYPT_VALUES else "other",
        "min_protocol": "default" if proto is None else (proto if proto in SMB_PROTOCOLS else "other"),
    }


def audit_units(timeout: int) -> dict:
    if tool("systemctl") is None:
        return {}
    units = {}
    for unit in UNITS:
        _, active = run(["systemctl", "is-active", unit], timeout)
        _, enabled = run(["systemctl", "is-enabled", unit], timeout)
        active, enabled = active.strip() or "unknown", enabled.strip() or "unknown"
        units[unit] = {
            "active": active if active in ACTIVE_STATES else "unknown",
            "enabled": enabled if enabled in ENABLED_STATES else "unknown",
        }
    return units


def findings(tcp: dict, udp: dict, ssh: dict | None, samba: dict | None) -> list[str]:
    out: list[str] = []
    tp, up = tcp["ports"], udp["ports"]
    exposed = lambda ports, p: bool(set(ports.get(p, {}).get("scopes", [])) - {"loopback"})  # noqa: E731
    wild = lambda ports, p: "wildcard" in ports.get(p, {}).get("scopes", [])  # noqa: E731
    ssh_ports = ssh["ports"] if ssh else [22]
    if any(wild(tp, p) for p in ssh_ports):
        out.append("ssh_listens_on_wildcard")
    if ssh is None and any(p in tp for p in ssh_ports):
        out.append("ssh_config_not_evaluated")
    if ssh:
        views = [ssh["global"], *ssh["contexts"].values()]
        if any(v["password_auth"] or v["kbd_interactive"] for v in views):
            out.append("ssh_password_or_interactive_auth_possible")
        if any(v["root_login"] != "no" for v in views):
            out.append("ssh_root_login_not_disabled")
        if any(v["any_forwarding"] for v in views):
            out.append("ssh_forwarding_enabled")
        if any(v["max_auth_tries_low"] for v in views):
            out.append("ssh_max_auth_tries_may_lock_out_agents")
        if ssh["contexts"]["stranger"]["password_auth"]:
            out.append("ssh_unmatched_peer_may_use_password")
        if any(v["differs_from_global"] for v in ssh["contexts"].values()):
            out.append("ssh_match_rules_change_policy")
    smb_listening = any(p in tp for p in (139, 445))
    if wild(tp, 445) or wild(tp, 139):
        out.append("smb_listens_on_wildcard")
        if samba and not samba["bind_interfaces_only"]:
            out.append("smb_not_bound_to_interfaces")
    if smb_listening and samba is None:
        out.append("samba_config_not_evaluated")
    if samba and (samba["guest_map_enabled"] or samba["guest_share_present"]):
        out.append("smb_guest_access_possible")
    if exposed(up, 137) or exposed(up, 138):
        out.append("netbios_udp_listening")
    if exposed(tp, 111) or exposed(up, 111):
        out.append("rpcbind_listening_non_loopback")
    if exposed(tp, 5900) or tcp["vnc_exposed_count"]:
        out.append("vnc_listening_non_loopback")
    if wild(tp, 5900):
        out.append("vnc_listens_on_wildcard")
    if tcp["wildcard_other_count"]:
        out.append("other_wildcard_listeners_present")
    return out


def read_contexts(path: str) -> list[str]:
    try:
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid not in (0, os.getuid()):
            raise AuditError("context_file_unsafe")
        with open(path, encoding="utf-8") as handle:
            return [l.strip() for l in handle if l.strip() and not l.lstrip().startswith("#")]
    except (OSError, UnicodeDecodeError) as exc:
        raise AuditError("context_file_unreadable") from exc


def build_parser() -> argparse.ArgumentParser:
    parser = QuietParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--role", required=True, help="short label such as nas or control-node (echoed)")
    parser.add_argument("--context", action="append", default=[], metavar="USER@ADDRESS",
                        help="evaluate sshd for this account and source address (repeatable)")
    parser.add_argument("--context-file", metavar="FILE",
                        help="owner-only (0600) file with one USER@ADDRESS per line; avoids argv exposure")
    parser.add_argument("--timeout", type=int, default=10)
    parser.add_argument("--fail-on-findings", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if not ROLE.fullmatch(args.role):
            raise AuditError("invalid_role")
        contexts = list(args.context) + (read_contexts(args.context_file) if args.context_file else [])
        for ctx in contexts:
            match = CONTEXT.fullmatch(ctx)
            if not match:
                raise AuditError("invalid_context")
            try:
                ipaddress.ip_address(match.group(2))
            except ValueError as exc:
                raise AuditError("invalid_context") from exc
        ssh = audit_ssh(contexts, args.timeout)
        ssh_ports = ssh["ports"] if ssh else [22]
        tcp_text = ""
        for flags in ("-ltnp", "-ltn"):
            rc, tcp_text = run(["ss", "-H", flags], args.timeout)
            if rc == 0:
                break
        if rc != 0:
            raise AuditError("listeners_unreadable")
        udp_text = ""
        for flags in ("-lunp", "-lun"):
            rc, udp_text = run(["ss", "-H", flags], args.timeout)
            if rc == 0:
                break
        if rc != 0:
            raise AuditError("listeners_unreadable")
        tcp = parse_listeners(tcp_text, tuple(sorted(set(OBSERVED_TCP) | set(ssh_ports))))
        udp = parse_listeners(udp_text, OBSERVED_UDP)
        samba = audit_samba(args.timeout)
        found = findings(tcp, udp, ssh, samba)
        report = {
            "schema": SCHEMA_VERSION,
            "role": args.role,
            "result": "findings" if found else "clean",
            "findings": found,
            "tcp_listeners": {str(p): v for p, v in sorted(tcp["ports"].items())},
            "udp_listeners": {str(p): v for p, v in sorted(udp["ports"].items())},
            "other_wildcard_listener_count": tcp["wildcard_other_count"],
            "ssh": ssh,
            "samba": samba,
            "units": audit_units(args.timeout),
            "controls_not_evaluated": [
                "router_boundary", "peer_reachability", "firewall_rules", "authentication_success", "ssh_admission_filters",
            ],
        }
    except AuditError as exc:
        print(json.dumps({"schema": SCHEMA_VERSION, "result": "error", "code": str(exc)}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 3 if found and args.fail_on_findings else 0


if __name__ == "__main__":
    sys.exit(main())
