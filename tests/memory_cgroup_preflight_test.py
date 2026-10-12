#!/usr/bin/env python3
"""Hermetic contract tests for scripts/memory-cgroup-preflight.py."""

from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


_REASONS = {
    "controller_absent",
    "delegation_absent",
    "delegation_unknown",
    "accounting_unavailable",
    "limit_mismatch",
    "membership_unverified",
    "cgroup_unavailable",
    "enforcement_unverified",
}


def _module_path() -> Path:
    if value := os.environ.get("BROKKR_MEMORY_CGROUP_PREFLIGHT_MODULE"):
        return Path(value)
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        return Path(sys.argv[1])
    return Path(__file__).resolve().parents[1] / "scripts" / "memory-cgroup-preflight.py"


def _load_target():
    path = _module_path()
    spec = importlib.util.spec_from_file_location(
        "brokkr_memory_cgroup_preflight_target", path
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot import target module: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if not callable(getattr(module, "inspect", None)):
        raise AttributeError("target module must expose inspect(...)" )
    return module


TARGET = _load_target()


def _tree_snapshot(root: Path) -> dict[str, tuple[str, bytes | str]]:
    snapshot: dict[str, tuple[str, bytes | str]] = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            snapshot[relative] = ("symlink", os.readlink(path))
        elif path.is_file():
            snapshot[relative] = ("file", path.read_bytes())
        elif path.is_dir():
            snapshot[relative] = ("directory", b"")
    return snapshot


class MemoryCgroupPreflightTests(unittest.TestCase):
    expected_memory = 5 * 1024**3
    expected_swap = 2 * 1024**3

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="brokkr-memory-cgroup-")
        self.root = Path(self.tempdir.name)
        self.proc = self.root / "proc"
        self.cgroup = self.root / "sys" / "fs" / "cgroup"
        self.manager_group = "/user.slice/user@1000.service"
        self.own_group = "/user.slice/test.service"
        self._write_proc("self/cgroup", "0::/user.slice/test.service\n")
        self._write_proc("pressure/memory", "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n")
        self._write_cgroup("cgroup.controllers", "cpu io memory pids\n")
        self._write_cgroup(
            "user.slice/user@1000.service/cgroup.controllers", "cpu io memory pids\n"
        )
        self._write_cgroup("user.slice/test.service/cgroup.controllers", "cpu io memory pids\n")
        self._write_cgroup("user.slice/test.service/memory.max", str(self.expected_memory) + "\n")
        self._write_cgroup("user.slice/test.service/memory.swap.max", str(self.expected_swap) + "\n")
        self._write_cgroup("user.slice/test.service/memory.current", "900\n")
        self._write_cgroup("user.slice/test.service/memory.swap.current", "20\n")
        self._write_cgroup(
            "user.slice/test.service/memory.stat",
            "anon 100\nfile 800\nshmem 200\ninactive_file 300\n",
        )
        self._write_cgroup("user.slice/test.service/cgroup.procs", "123\n456\n")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _write_proc(self, relative: str, content: str) -> Path:
        path = self.proc / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def _write_cgroup(self, relative: str, content: str) -> Path:
        path = self.cgroup / relative.lstrip("/")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def _inspect(self, **kwargs):
        arguments = {
            "proc_root": self.proc,
            "cgroup_root": self.cgroup,
            "manager_group": self.manager_group,
            "expected_memory": self.expected_memory,
            "expected_swap": self.expected_swap,
            "pid": 123,
        }
        arguments.update(kwargs)
        return TARGET.inspect(**arguments)

    def _assert_result_shape(self, result: dict) -> None:
        self.assertIn(result.get("status"), {"supported", "unverified", "unsupported"})
        self.assertIsInstance(result.get("reasons"), list)
        self.assertTrue(set(result["reasons"]).issubset(_REASONS))
        self.assertIsInstance(result.get("psi_available"), bool)

    def test_supported_with_effective_limits_and_complete_accounting(self) -> None:
        result = self._inspect()
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "supported")
        self.assertNotIn("enforcement_unverified", result["reasons"])
        self.assertTrue(result["psi_available"])
        self.assertEqual(
            result["memory"],
            {
                "max": self.expected_memory,
                "swap_max": self.expected_swap,
                "current": 900,
                "swap_current": 20,
                "anon": 100,
                "file": 800,
                "shmem": 200,
                "inactive_file": 300,
                "file_cache_bytes": 600,
            },
        )

    def test_zero_swap_limit_is_verified_from_actual_cgroup(self):
        self._write_cgroup("user.slice/test.service/memory.swap.max", "0\n")
        result = self._inspect(expected_swap=0)
        self.assertEqual(result["status"], "supported")
        self.assertEqual(result["memory"]["swap_max"], 0)

    def test_missing_psi_does_not_block_supported_result(self) -> None:
        (self.proc / "pressure" / "memory").unlink()
        result = self._inspect()
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "supported")
        self.assertFalse(result["psi_available"])

    def test_missing_root_controller_is_unsupported(self) -> None:
        self._write_cgroup("cgroup.controllers", "cpu io pids\n")
        result = self._inspect(expected_memory=None, expected_swap=None)
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("controller_absent", result["reasons"])

    def test_missing_manager_delegation_is_unsupported(self) -> None:
        self._write_cgroup(
            "user.slice/user@1000.service/cgroup.controllers", "cpu io pids\n"
        )
        result = self._inspect(expected_memory=None, expected_swap=None)
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("delegation_absent", result["reasons"])

    def test_unknown_manager_group_is_not_claimed_as_delegated(self) -> None:
        result = self._inspect(manager_group=None, expected_memory=None, expected_swap=None)
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unverified")
        self.assertIn("delegation_unknown", result["reasons"])

    def test_effective_process_cgroup_can_support_without_manager_query(self) -> None:
        result = self._inspect(manager_group=None)
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "supported")
        self.assertNotIn("delegation_unknown", result["reasons"])

    def test_unlimited_or_mismatched_limit_refuses_enforcement_claim(self) -> None:
        cases = (
            ("memory.max", "max", "unlimited memory"),
            ("memory.max", str(self.expected_memory + 1), "mismatched memory"),
            ("memory.swap.max", "max", "unlimited swap"),
            ("memory.swap.max", str(self.expected_swap + 1), "mismatched swap"),
        )
        for filename, value, label in cases:
            with self.subTest(label=label):
                original = str(
                    self.expected_memory
                    if filename == "memory.max"
                    else self.expected_swap
                )
                self._write_cgroup("user.slice/test.service/" + filename, value + "\n")
                result = self._inspect()
                self._assert_result_shape(result)
                self.assertEqual(result["status"], "unsupported")
                self.assertIn("limit_mismatch", result["reasons"])
                self._write_cgroup("user.slice/test.service/" + filename, original + "\n")

    def test_missing_expected_limits_is_unverified(self) -> None:
        for expected_memory, expected_swap in ((None, None), (self.expected_memory, None)):
            with self.subTest(expected_memory=expected_memory, expected_swap=expected_swap):
                result = self._inspect(
                    expected_memory=expected_memory,
                    expected_swap=expected_swap,
                )
                self._assert_result_shape(result)
                self.assertEqual(result["status"], "unverified")
                self.assertIn("enforcement_unverified", result["reasons"])

    def test_missing_or_malformed_accounting_is_unsupported(self) -> None:
        cases = (
            ("user.slice/test.service/memory.stat", "anon 100\nfile 800\nshmem 200\n"),
            ("user.slice/test.service/memory.stat", "anon 100\nfile malformed\nshmem 200\ninactive_file 300\n"),
            ("user.slice/test.service/memory.stat", None),
            ("user.slice/test.service/memory.current", None),
            ("user.slice/test.service/memory.swap.current", None),
        )
        for filename, content in cases:
            with self.subTest(filename=filename, content=content):
                path = self.cgroup / filename
                original = path.read_text(encoding="utf-8")
                if content is None:
                    path.unlink()
                else:
                    path.write_text(content, encoding="utf-8")
                result = self._inspect()
                self._assert_result_shape(result)
                self.assertEqual(result["status"], "unsupported")
                self.assertIn("accounting_unavailable", result["reasons"])
                path.write_text(original, encoding="utf-8")

    def test_negative_accounting_counter_is_unsupported(self) -> None:
        for filename, content in (
            ("memory.current", "-1\n"),
            ("memory.stat", "anon -1\nfile 800\nshmem 200\ninactive_file 300\n"),
        ):
            with self.subTest(filename=filename):
                path = self.cgroup / "user.slice/test.service" / filename
                original = path.read_text(encoding="utf-8")
                path.write_text(content, encoding="utf-8")
                result = self._inspect()
                self._assert_result_shape(result)
                self.assertEqual(result["status"], "unsupported")
                self.assertIn("accounting_unavailable", result["reasons"])
                path.write_text(original, encoding="utf-8")

    def test_missing_pid_is_membership_unverified(self) -> None:
        self._write_cgroup("user.slice/test.service/cgroup.procs", "456\n")
        result = self._inspect()
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unverified")
        self.assertIn("membership_unverified", result["reasons"])

    def test_parent_traversal_is_rejected_without_reading_outside_root(self) -> None:
        outside = self.cgroup.parent / "escape.service"
        outside.mkdir()
        (outside / "memory.max").write_text(str(self.expected_memory), encoding="utf-8")
        self._write_proc("self/cgroup", "0::/user.slice/../escape.service\n")
        before = _tree_snapshot(self.root)
        result = self._inspect()
        after = _tree_snapshot(self.root)
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("cgroup_unavailable", result["reasons"])
        self.assertEqual(before, after)

    def test_root_cgroup_is_rejected(self) -> None:
        self._write_proc("self/cgroup", "0::/\n")
        result = self._inspect()
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("cgroup_unavailable", result["reasons"])

    def test_symlink_cgroup_is_rejected(self) -> None:
        link = self.cgroup / "user.slice" / "linked.service"
        link.symlink_to("test.service", target_is_directory=True)
        self._write_proc("self/cgroup", "0::/user.slice/linked.service\n")
        result = self._inspect()
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("cgroup_unavailable", result["reasons"])

    def test_result_does_not_expose_paths_or_secret_content(self) -> None:
        self._write_cgroup(
            "user.slice/test.service/memory.stat",
            "anon secret-sentinel\nfile 800\nshmem 200\ninactive_file 300\n",
        )
        result = self._inspect()
        rendered = repr(result)
        self._assert_result_shape(result)
        self.assertEqual(result["status"], "unsupported")
        self.assertIn("accounting_unavailable", result["reasons"])
        self.assertNotIn(str(self.root), rendered)
        self.assertNotIn("secret-sentinel", rendered)

    def test_inspection_does_not_mutate_fixture_tree(self) -> None:
        before = _tree_snapshot(self.root)
        result = self._inspect()
        after = _tree_snapshot(self.root)
        self._assert_result_shape(result)
        self.assertEqual(before, after)


class KernelDiagnosisTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="brokkr-memory-diagnosis-")
        self.proc = Path(self.tempdir.name) / "proc"
        self.proc.mkdir()

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _write(self, relative: str, content: str) -> None:
        path = self.proc / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def test_diagnosis_reports_allowlisted_boot_and_config_flags(self) -> None:
        self._write(
            "cmdline",
            "BOOT_IMAGE=/boot/vmlinuz-secret-token cgroup_disable=memory "
            "cgroup_enable=memory psi=0 quiet\n",
        )
        self._write("cgroups", "#subsys_name hierarchy num_cgroups enabled\nmemory 1 4 1\n")
        result = TARGET.kernel_diagnosis(
            self.proc,
            "# CONFIG_MEMCG is not set\n# CONFIG_PSI is not set\nCONFIG_PSI_DEFAULT_DISABLED=y\n",
        )
        self.assertEqual(
            result["boot"],
            {
                "memory_disabled": True,
                "memory_enable_requested": True,
                "memory_bound_to_v1": True,
                "psi_disabled": True,
            },
        )
        self.assertEqual(result["kernel"]["CONFIG_MEMCG"], "disabled")
        self.assertEqual(result["kernel"]["CONFIG_PSI"], "disabled")
        self.assertEqual(result["kernel"]["CONFIG_PSI_DEFAULT_DISABLED"], "enabled")
        rendered = json.dumps(result, sort_keys=True)
        self.assertNotIn("secret-token", rendered)
        self.assertNotIn(str(self.proc), rendered)

    def test_absent_config_flags_remain_unknown(self) -> None:
        self._write("cmdline", "quiet\n")
        self._write("cgroups", "#subsys_name hierarchy num_cgroups enabled\nmemory 0 1 1\n")
        result = TARGET.kernel_diagnosis(self.proc, "CONFIG_SOMETHING_ELSE=y\n")
        self.assertEqual(result["kernel"]["CONFIG_MEMCG"], "unknown")
        self.assertEqual(result["kernel"]["CONFIG_PSI"], "unknown")
        self.assertEqual(result["kernel"]["CONFIG_PSI_DEFAULT_DISABLED"], "unknown")
        self.assertFalse(result["boot"]["memory_bound_to_v1"])


class MountAndManagerProbeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory(prefix="brokkr-memory-mount-")
        self.proc = Path(self.tempdir.name) / "proc"
        self.proc.mkdir()

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _mountinfo(self, root: str, mountpoint: str) -> None:
        (self.proc / "self").mkdir(parents=True, exist_ok=True)
        (self.proc / "self/mountinfo").write_text(
            f"36 25 0:31 {root} {mountpoint} rw,relatime - cgroup2 cgroup rw\n",
            encoding="utf-8",
        )

    def test_mounted_root_accepts_host_root_cgroup2_mount_and_decodes_path(self) -> None:
        self._mountinfo("/", "/sys/fs/cgroup\\040root")
        self.assertEqual(TARGET.mounted_root(self.proc), Path("/sys/fs/cgroup root"))

    def test_mounted_root_rejects_subtree_cgroup2_mount(self) -> None:
        self._mountinfo("/user.slice", "/sys/fs/cgroup/user.slice")
        with self.assertRaises(TARGET.Unavailable):
            TARGET.mounted_root(self.proc)

    def test_manager_probe_is_read_only_bounded_and_redacts_stderr(self) -> None:
        response = mock.Mock(returncode=0, stdout="/user.slice/user@1000.service\n", stderr="secret-cmdline")
        with mock.patch.object(TARGET.subprocess, "run", return_value=response) as run:
            result = TARGET.manager_group()
        self.assertEqual(result, "/user.slice/user@1000.service")
        run.assert_called_once_with(
            ["systemctl", "--user", "show", "--property=ControlGroup", "--value", "--", "-.slice"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
        self.assertNotIn("secret-cmdline", repr(result))


class CliTests(unittest.TestCase):
    def test_invalid_incomplete_and_negative_limits_fail_before_probe(self) -> None:
        cases = (
            ["memory-cgroup-preflight", "--expect-memory-max", "10"],
            ["memory-cgroup-preflight", "--expect-memory-max", "-1", "--expect-swap-max", "0"],
        )
        for argv in cases:
            with self.subTest(argv=argv), mock.patch.object(sys, "argv", argv), \
                    mock.patch.object(TARGET, "mounted_root") as mounted_root, \
                    mock.patch.object(TARGET, "manager_group") as manager_group, \
                    mock.patch.object(TARGET, "running_config") as running_config, \
                    mock.patch.object(TARGET, "inspect") as inspect:
                with self.assertRaises(SystemExit) as error:
                    TARGET.main()
                self.assertEqual(error.exception.code, 2)
                mounted_root.assert_not_called()
                manager_group.assert_not_called()
                running_config.assert_not_called()
                inspect.assert_not_called()

    def test_no_cgroup_mount_still_reports_psi_independently(self):
        with mock.patch.object(sys, "argv", ["preflight"]), \
                mock.patch.object(TARGET, "mounted_root", side_effect=TARGET.Unavailable()), \
                mock.patch.object(TARGET, "read", return_value="some avg10=0"), \
                mock.patch.object(TARGET, "running_config", return_value=None), \
                mock.patch.object(TARGET, "kernel_diagnosis", return_value={}), \
                mock.patch.object(sys, "stdout", new_callable=io.StringIO) as output:
            self.assertEqual(TARGET.main(), 1)
        self.assertTrue(json.loads(output.getvalue())["psi_available"])

    def test_valid_cli_emits_json_and_uses_read_only_probes(self) -> None:
        expected = {
            "schema_version": 1,
            "status": "supported",
            "reasons": [],
            "psi_available": False,
            "controller": "available",
            "delegation": "unknown",
            "memory": {"max": 10, "swap_max": 0},
        }
        diagnosis = {"boot": {}, "kernel": {}}
        with mock.patch.object(sys, "argv", ["memory-cgroup-preflight", "--expect-memory-max", "10", "--expect-swap-max", "0"]), \
                mock.patch.object(TARGET, "mounted_root", return_value=Path("/fixture/cgroup")) as mounted_root, \
                mock.patch.object(TARGET, "manager_group", return_value=None) as manager_group, \
                mock.patch.object(TARGET, "running_config", return_value=None) as running_config, \
                mock.patch.object(TARGET, "inspect", return_value=expected) as inspect, \
                mock.patch.object(TARGET, "kernel_diagnosis", return_value=diagnosis):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                code = TARGET.main()
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(output.getvalue()), {**expected, "diagnosis": diagnosis})
        mounted_root.assert_called_once_with(Path("/proc"))
        manager_group.assert_called_once_with()
        running_config.assert_called_once_with()
        inspect.assert_called_once()
        self.assertNotIn("/fixture/cgroup", output.getvalue())


if __name__ == "__main__":
    # The first positional argument is the target module path; keep unittest's
    # own argv clean so the wrapper can pass normal unittest options afterward.
    if len(sys.argv) > 1 and not sys.argv[1].startswith("-"):
        sys.argv.pop(1)
    unittest.main()
