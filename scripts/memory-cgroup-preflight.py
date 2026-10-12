#!/usr/bin/env python3
"""Read-only cgroup-v2 memory evidence; never writes cgroups or starts units."""
import argparse
import gzip
import json
import os
from pathlib import Path
import re
import subprocess


class Unavailable(ValueError):
    """Missing, malformed or unsafe evidence (no private locator in errors)."""


def read(path):
    try:
        return path.read_text(encoding="utf-8").strip()
    except (OSError, UnicodeError) as error:
        raise Unavailable("unreadable evidence") from error


def number(text):
    if not re.fullmatch(r"[0-9]{1,19}", text) or int(text) > 2**63 - 1:
        raise Unavailable("invalid counter")
    return int(text)


def group_path(root, group):
    if not group or not group.startswith("/") or group == "/":
        raise Unavailable("non-root cgroup required")
    parts = group[1:].split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise Unavailable("invalid cgroup")
    path = root.joinpath(*parts)
    if path.resolve() != root.resolve().joinpath(*parts):
        raise Unavailable("symlink cgroup")
    return path


def own_group(proc_root):
    groups = [line[3:] for line in read(proc_root / "self/cgroup").splitlines()
              if line.startswith("0::")]
    if len(groups) != 1:
        raise Unavailable("unified cgroup unavailable")
    return groups[0]


def inspect(proc_root, cgroup_root, manager_group, expected_memory=None,
            expected_swap=None, pid=123):
    """Pure observation API; roots are injected only by hermetic unit tests."""
    result = {"schema_version": 1, "status": "unsupported", "reasons": [],
              "psi_available": False, "controller": "unknown",
              "delegation": "unknown", "memory": {}}
    reasons = result["reasons"]
    try:
        read(proc_root / "pressure/memory")
        result["psi_available"] = True
    except Unavailable:
        pass
    try:
        controllers = read(cgroup_root / "cgroup.controllers").split()
    except Unavailable:
        reasons.append("cgroup_unavailable")
        return result
    result["controller"] = "available" if "memory" in controllers else "absent"
    if result["controller"] == "absent":
        reasons.append("controller_absent")
        return result
    if manager_group is not None:
        try:
            manager = group_path(cgroup_root, manager_group)
            result["delegation"] = ("available" if "memory" in
                                    read(manager / "cgroup.controllers").split() else "absent")
        except Unavailable:
            result["delegation"] = "unknown"
    expected = expected_memory is not None and expected_swap is not None
    if not expected and result["delegation"] == "absent":
        reasons.append("delegation_absent")
        return result
    if expected and (type(expected_memory) is not int or type(expected_swap) is not int
                     or not 0 < expected_memory <= 2**63 - 1
                     or not 0 <= expected_swap <= 2**63 - 1):
        reasons.append("limit_mismatch")
        return result
    try:
        group = own_group(proc_root)
        actual = group_path(cgroup_root, group)
    except Unavailable:
        reasons.append("cgroup_unavailable")
        return result
    try:
        memory = result["memory"]
        for key, filename in (("max", "memory.max"), ("swap_max", "memory.swap.max"),
                              ("current", "memory.current"), ("swap_current", "memory.swap.current")):
            value = read(actual / filename)
            memory[key] = value if key in ("max", "swap_max") and value == "max" else number(value)
        stats = {}
        for line in read(actual / "memory.stat").splitlines():
            fields = line.split()
            if len(fields) != 2 or fields[0] in stats:
                raise Unavailable("invalid memory statistics")
            stats[fields[0]] = number(fields[1])
        for key in ("anon", "file", "shmem", "inactive_file"):
            if key not in stats:
                raise Unavailable("incomplete memory statistics")
            memory[key] = stats[key]
        # shmem is included in file, so avoid double-counting shared working memory.
        memory["file_cache_bytes"] = max(0, memory["file"] - memory["shmem"])
    except Unavailable:
        reasons.append("accounting_unavailable")
        return result
    try:
        if str(pid) not in read(actual / "cgroup.procs").split():
            raise Unavailable("process not in cgroup")
        if own_group(proc_root) != group:
            raise Unavailable("process moved during observation")
    except Unavailable:
        reasons.append("membership_unverified")
        result["status"] = "unverified"
        return result
    if expected:
        if memory["max"] != expected_memory or memory["swap_max"] != expected_swap:
            reasons.append("limit_mismatch")
        else:
            # Actual process cgroup evidence supersedes an unavailable manager query.
            result["status"] = "supported"
    elif result["delegation"] == "absent":
        reasons.append("delegation_absent")
    else:
        if result["delegation"] == "unknown":
            reasons.append("delegation_unknown")
        reasons.append("enforcement_unverified")
        result["status"] = "unverified"
    return result


def kernel_diagnosis(proc_root, config=None):
    """Allowlisted flags only: never publish raw boot arguments or kernel config."""
    flags = {"memory_disabled": None, "memory_enable_requested": None,
             "memory_bound_to_v1": None, "psi_disabled": None}
    try:
        tokens = read(proc_root / "cmdline").split()
        flags.update(memory_disabled=any(t.startswith("cgroup_disable=") and
                                        "memory" in t.split("=", 1)[1].split(",") for t in tokens),
                     memory_enable_requested=any(t.startswith("cgroup_enable=") and
                                                 "memory" in t.split("=", 1)[1].split(",") for t in tokens),
                     psi_disabled="psi=0" in tokens)
    except Unavailable:
        pass
    try:
        rows = [line.split() for line in read(proc_root / "cgroups").splitlines()
                if not line.startswith("#")]
        memory = [row for row in rows if len(row) == 4 and row[0] == "memory"]
        if len(memory) == 1:
            flags["memory_bound_to_v1"] = number(memory[0][1]) > 0
    except Unavailable:
        pass
    options = {}
    for key in ("CONFIG_MEMCG", "CONFIG_PSI", "CONFIG_PSI_DEFAULT_DISABLED"):
        options[key] = "unknown"
        if config is not None:
            if re.search(rf"^{key}=y$", config, re.M):
                options[key] = "enabled"
            elif re.search(rf"^(?:# {key} is not set|{key}=n)$", config, re.M):
                options[key] = "disabled"
    return {"boot": flags, "kernel": options}


def mounted_root(proc_root):
    # Host view only. Subtree mounts/container namespace remapping need their own contract.
    roots = []
    for line in read(proc_root / "self/mountinfo").splitlines():
        before, separator, after = line.partition(" - ")
        fields = before.split()
        if separator and after.split()[0:1] == ["cgroup2"] and len(fields) >= 6:
            if fields[3] != "/":
                continue
            decoded = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields[4])
            if decoded.startswith("/"):
                roots.append(Path(decoded))
    if len(roots) != 1:
        raise Unavailable("unambiguous host cgroup2 mount required")
    return roots[0]


def manager_group():
    try:
        response = subprocess.run(["systemctl", "--user", "show", "--property=ControlGroup",
                                   "--value", "--", "-.slice"], capture_output=True,
                                  text=True, timeout=3, check=False)
        return response.stdout.strip() if response.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, UnicodeError):
        return None


def running_config():
    try:
        with gzip.open("/proc/config.gz", "rt", encoding="utf-8") as stream:
            return stream.read()
    except (OSError, EOFError, UnicodeError):
        # No module loading. The packaged config may be available without IKCONFIG_PROC.
        try:
            return read(Path("/boot") / ("config-" + os.uname().release))
        except Unavailable:
            return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expect-memory-max", type=int, help="expected finite memory.max in bytes")
    parser.add_argument("--expect-swap-max", type=int, help="expected finite memory.swap.max in bytes")
    parser.add_argument("--dry-run", action="store_true", help="same read-only observation; no mutation mode exists")
    args = parser.parse_args()
    if ((args.expect_memory_max is None) != (args.expect_swap_max is None)
            or (args.expect_memory_max is not None and not 0 < args.expect_memory_max <= 2**63 - 1)
            or (args.expect_swap_max is not None and not 0 <= args.expect_swap_max <= 2**63 - 1)):
        parser.error("both expected limits are required; memory must be positive and swap nonnegative")
    proc = Path("/proc")
    try:
        root = mounted_root(proc)
        result = inspect(proc, root, manager_group(), args.expect_memory_max,
                         args.expect_swap_max, os.getpid())
    except Unavailable:
        result = {"schema_version": 1, "status": "unsupported", "reasons": ["cgroup_unavailable"],
                  "psi_available": False, "controller": "unknown", "delegation": "unknown", "memory": {}}
    try:
        read(proc / "pressure/memory")
        result["psi_available"] = True
    except Unavailable:
        result["psi_available"] = False
    result["diagnosis"] = kernel_diagnosis(proc, running_config())
    print(json.dumps(result, sort_keys=True))
    return {"supported": 0, "unsupported": 1, "unverified": 2}[result["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
