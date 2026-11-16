#!/usr/bin/env python3
"""Read-only, content-blind block-layer encryption inventory for a host.

Answers one question per owner-labelled store: is the block-device stack under this mount encrypted
(a `crypt` device in its ancestry), absent, or unknown? It reads `lsblk -J` topology and `findmnt`
only. It never reads a file, key, header, UUID, device name, mount path or label.

The owner supplies stores as `--store LABEL=/mount/point` (or one per line in an owner-only
`--store-file`, so mount paths stay out of argv, which sudo logs). Use `swap=[SWAP]` to include swap. LABEL (snake_case) is echoed; the mount
point is used only to resolve the stack and is never printed. `/` is always included as `root`.

Block-layer protection only: "absent" here is not proof that an application, file or backup copy is
unencrypted, and "encrypted" is not proof of key recovery or restore. Those need owner evidence.

Also reports coarse capability facts that bound the design: a TPM device node, an initramfs crypt
setup file, installed cryptsetup, and the boot medium class of the root stack (sd, usb, nvme, sata,
unknown).

Output: one JSON line, no stderr. Exit 0 report written, 1 error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import subprocess
import sys

SCHEMA_VERSION = "v1"
LABEL = re.compile(r"[a-z][a-z0-9_]{0,31}")
STORE = re.compile(r"([a-z][a-z0-9_]{0,31})=(/[^\x00]*|\[SWAP\])")


class InventoryError(Exception):
    pass


def run(argv: list[str], timeout: int) -> str:
    try:
        done = subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InventoryError("command_failed") from exc
    if done.returncode != 0:
        raise InventoryError("command_failed")
    return done.stdout


def find_stacks(nodes: list[dict], target: str, chain: tuple[dict, ...] = ()) -> list[tuple[dict, ...]]:
    """Return the ancestry chains (disk first) that end in a node mounted at target."""
    found: list[tuple[dict, ...]] = []
    for node in nodes:
        here = chain + (node,)
        mounts = node.get("mountpoints") or [node.get("mountpoint")]
        if target in [m for m in mounts if m]:
            found.append(here)
        found.extend(find_stacks(node.get("children") or [], target, here))
    return found


def transport_class(chain: tuple[dict, ...]) -> str:
    disk = chain[0]
    name, tran = str(disk.get("name", "")), str(disk.get("tran") or "")
    if name.startswith("mmcblk") or tran == "mmc":
        return "sd"
    if tran == "usb":
        return "usb"
    if name.startswith("nvme") or tran == "nvme":
        return "nvme"
    if tran in ("sata", "ata"):
        return "sata"
    return "unknown"


def protection(chains: list[tuple[dict, ...]]) -> str:
    if not chains:
        return "unknown"
    states = {"encrypted" if any(str(n.get("type")) == "crypt" for n in c) else "absent" for c in chains}
    return states.pop() if len(states) == 1 else "unknown"


def resolve_mount(path: str, timeout: int) -> str:
    if path == "[SWAP]":
        return path
    out = run(["findmnt", "-n", "-o", "TARGET", "--target", path], timeout).strip()
    return out.splitlines()[0] if out else ""


def crypttab_entries() -> int:
    try:
        with open("/etc/crypttab", encoding="utf-8", errors="replace") as handle:
            return sum(1 for l in handle if l.strip() and not l.lstrip().startswith("#"))
    except OSError:
        return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--role", required=True)
    parser.add_argument("--store", action="append", default=[], metavar="LABEL=/MOUNT")
    parser.add_argument("--store-file", metavar="FILE",
                        help="owner-only (0600) file with one LABEL=/MOUNT per line; avoids argv exposure")
    parser.add_argument("--timeout", type=int, default=10)
    args = parser.parse_args(argv)
    try:
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,31}", args.role):
            raise InventoryError("invalid_role")
        stores = {"root": "/"}
        items = list(args.store)
        if args.store_file:
            try:
                info = os.stat(args.store_file)
                if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_uid not in (0, os.getuid()):
                    raise InventoryError("store_file_unsafe")
                with open(args.store_file, encoding="utf-8") as handle:
                    items += [l.strip() for l in handle if l.strip() and not l.lstrip().startswith("#")]
            except (OSError, UnicodeDecodeError) as exc:
                raise InventoryError("store_file_unreadable") from exc
        for item in items:
            match = STORE.fullmatch(item)
            if not match or match.group(1) == "root" or match.group(1) in stores:
                raise InventoryError("invalid_store")
            stores[match.group(1)] = match.group(2)
        for tool in ("lsblk", "findmnt"):
            if shutil.which(tool) is None:
                raise InventoryError(f"{tool}_missing")
        try:
            try:
                raw = run(["lsblk", "-J", "-o", "NAME,TYPE,TRAN,MOUNTPOINTS"], args.timeout)
            except InventoryError:  # util-linux < 2.37 has no MOUNTPOINTS column
                raw = run(["lsblk", "-J", "-o", "NAME,TYPE,TRAN,MOUNTPOINT"], args.timeout)
            tree = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise InventoryError("lsblk_unparseable") from exc
        nodes = tree.get("blockdevices")
        if not isinstance(nodes, list):
            raise InventoryError("lsblk_unparseable")
        result, root_chains = {}, []
        for label, path in stores.items():
            try:
                mount = resolve_mount(path, args.timeout)
            except InventoryError:
                mount = ""
            chains = find_stacks(nodes, mount) if mount else []
            if label == "root":
                root_chains = chains
            result[label] = {
                "block_layer": protection(chains),
                "stack_count": len(chains),
                "same_stack_as_root": bool(chains) and label != "root"
                and {id(c[0]) for c in chains} == {id(c[0]) for c in root_chains},
                "medium": transport_class(chains[0]) if chains else "unknown",
            }
        report = {
            "schema": SCHEMA_VERSION,
            "role": args.role,
            "stores": result,
            "capabilities": {
                "tpm_device_present": os.path.exists("/dev/tpmrm0") or os.path.exists("/dev/tpm0"),
                "cryptsetup_installed": shutil.which("cryptsetup") is not None,
                "crypttab_entries": crypttab_entries(),
                "initramfs_dropbear_present": os.path.isdir("/etc/dropbear/initramfs")
                or os.path.isdir("/etc/dropbear-initramfs"),
            },
            "not_evaluated": ["application_encryption", "backup_copy_encryption", "key_recovery", "restore"],
        }
    except InventoryError as exc:
        print(json.dumps({"schema": SCHEMA_VERSION, "result": "error", "code": str(exc)}, sort_keys=True))
        return 1
    print(json.dumps(report, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
