"""Filesystem tests for relocatable runtime-preview packages."""

import importlib.util
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/package-review-preview.py"


def load_packager():
    spec = importlib.util.spec_from_file_location("package_review_preview", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class PackagingTests(unittest.TestCase):
    def test_claude_package_is_relocatable_allowlisted_and_no_clobber(self):
        """Would fail if assembly omitted runtime files, copied production trees, or overwrote output."""
        build_package = load_packager().build_package
        with TemporaryDirectory() as temporary:
            package = build_package("claude-code", Path(temporary) / "preview")

            self.assertTrue((package / "lib/runtime-review.sh").is_file())
            self.assertTrue((package / "adapters/claude-code/preview/.claude-plugin/plugin.json").is_file())
            for production_path in (".claude-plugin", "agents", "hooks", "skills", "pipeline.json"):
                with self.subTest(production_path=production_path):
                    self.assertFalse((package / production_path).exists())
            self.assertFalse((package / "node_modules").exists())
            with self.assertRaises(FileExistsError):
                build_package("claude-code", package)

    def test_rejects_unknown_host_and_unsafe_destinations(self):
        """Would fail if invalid input could select extra source or write to an ambiguous location."""
        packager = load_packager()
        with TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            with self.assertRaisesRegex(ValueError, "unknown host"):
                packager.build_package("other", temporary_path / "unknown")
            with self.assertRaisesRegex(ValueError, "absolute"):
                packager.build_package("claude-code", Path("relative-preview"))

            destination_link = temporary_path / "destination-link"
            destination_link.symlink_to(temporary_path / "missing-target", target_is_directory=True)
            with self.assertRaises(FileExistsError):
                packager.build_package("claude-code", destination_link)

            original_root = packager.SOURCE_ROOT
            packager.SOURCE_ROOT = temporary_path / "source"
            packager.SOURCE_ROOT.mkdir()
            try:
                with self.assertRaisesRegex(ValueError, "source tree"):
                    packager.build_package("claude-code", packager.SOURCE_ROOT / "output")
            finally:
                packager.SOURCE_ROOT = original_root

    def test_rejects_source_symlinks_before_creating_destination(self):
        """Would fail if copytree followed a symlink out of an allowlisted source tree."""
        packager = load_packager()
        with TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            source = temporary_path / "source"
            (source / "lib/runtime_review").mkdir(parents=True)
            (source / "runtime/review").mkdir(parents=True)
            (source / "adapters/claude-code/preview").mkdir(parents=True)
            (source / "lib/config.sh").write_text("config\n", encoding="utf-8")
            (source / "lib/runtime-review.sh").write_text("runtime\n", encoding="utf-8")
            outside = temporary_path / "outside.txt"
            outside.write_text("must not be copied\n", encoding="utf-8")
            (source / "runtime/review/escape").symlink_to(outside)

            original_root = packager.SOURCE_ROOT
            packager.SOURCE_ROOT = source
            destination = temporary_path / "output"
            try:
                with self.assertRaisesRegex(ValueError, "source symlink"):
                    packager.build_package("claude-code", destination)
                self.assertFalse(destination.exists())
            finally:
                packager.SOURCE_ROOT = original_root

    def test_pi_package_contains_only_selected_sources_and_verifiable_evidence(self):
        """Would fail if packaging copied another host, installed dependencies, or wrong file hashes."""
        build_package = load_packager().build_package
        with TemporaryDirectory() as temporary:
            package = build_package("pi", Path(temporary) / "preview")

            self.assertTrue((package / "adapters/pi/preview/package.json").is_file())
            self.assertTrue((package / "adapters/pi/preview/package-lock.json").is_file())
            self.assertFalse((package / "adapters/claude-code").exists())
            self.assertFalse((package / "adapters/codex").exists())
            self.assertFalse(any(path.name == "node_modules" for path in package.rglob("*")))
            self.assertFalse(any(path.name == "__pycache__" for path in package.rglob("*")))
            self.assertEqual(
                {path.name for path in package.iterdir()},
                {"adapters", "lib", "runtime", "package-evidence.json"},
            )

            evidence = json.loads((package / "package-evidence.json").read_text(encoding="utf-8"))
            self.assertEqual(set(evidence), {"schemaVersion", "host", "files"})
            self.assertEqual(evidence["schemaVersion"], 1)
            self.assertEqual(evidence["host"], "pi")
            packaged_files = {
                path.relative_to(package).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in package.rglob("*")
                if path.is_file() and path.name != "package-evidence.json"
            }
            self.assertEqual(evidence["files"], packaged_files)

    def test_installed_pi_dependencies_are_ignored_and_packaging_executes_nothing(self):
        """Would fail if an installed dependency or package hook entered or ran during assembly."""
        packager = load_packager()
        with TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            source = temporary_path / "source"
            (source / "lib/runtime_review").mkdir(parents=True)
            (source / "runtime/review").mkdir(parents=True)
            adapter = source / "adapters/pi/preview"
            (adapter / "hooks").mkdir(parents=True)
            (adapter / "node_modules/.bin").mkdir(parents=True)
            (source / "lib/config.sh").write_text("config\n", encoding="utf-8")
            (source / "lib/runtime-review.sh").write_text("runtime\n", encoding="utf-8")
            (adapter / "package.json").write_text('{"private":true}\n', encoding="utf-8")
            (adapter / "package-lock.json").write_text('{"lockfileVersion":3}\n', encoding="utf-8")
            sentinel = temporary_path / "hook-ran"
            (adapter / "hooks/on-package.py").write_text(
                f"from pathlib import Path\nPath({str(sentinel)!r}).write_text('ran')\n",
                encoding="utf-8",
            )
            installed_cli = adapter / "node_modules/pi.js"
            installed_cli.write_text("installed dependency\n", encoding="utf-8")
            (adapter / "node_modules/.bin/pi").symlink_to(installed_cli)

            original_root = packager.SOURCE_ROOT
            packager.SOURCE_ROOT = source
            try:
                package = packager.build_package("pi", temporary_path / "output")
            finally:
                packager.SOURCE_ROOT = original_root

            self.assertFalse((package / "adapters/pi/preview/node_modules").exists())
            self.assertTrue((package / "adapters/pi/preview/hooks/on-package.py").is_file())
            self.assertFalse(sentinel.exists())

    def test_relocated_claude_bridge_stays_python_only(self):
        """Would fail if a moved Claude package depended on the checkout, Node, or Pi."""
        with TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            isolated_bin = temporary_path / "python-only-bin"
            isolated_bin.mkdir()
            (isolated_bin / "dirname").symlink_to(shutil.which("dirname"))
            (isolated_bin / "python3").symlink_to(sys.executable)
            self.assertIsNone(shutil.which("node", path=str(isolated_bin)))
            self.assertIsNone(shutil.which("pi", path=str(isolated_bin)))

            project = temporary_path / "project"
            home = temporary_path / "n1-home"
            project.mkdir()
            home.mkdir()
            isolated_environment = {
                "HOME": str(temporary_path / "home"),
                "LC_ALL": "C",
                "N1_HOME": str(home),
                "PATH": str(isolated_bin),
            }
            built = temporary_path / "built"
            packaged = subprocess.run(
                [
                    str(isolated_bin / "python3"),
                    str(SCRIPT),
                    "--host",
                    "claude-code",
                    "--destination",
                    str(built),
                ],
                cwd=project,
                env=isolated_environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(packaged.returncode, 0, packaged.stderr)

            relocated = temporary_path / "relocated" / "preview"
            relocated.parent.mkdir()
            built.rename(relocated)
            bridge = subprocess.run(
                ["/bin/bash", str(relocated / "lib/runtime-review.sh")],
                cwd=project,
                env=isolated_environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(bridge.returncode, 2)
            self.assertIn("required", bridge.stderr)
            self.assertNotIn(str(ROOT), bridge.stderr)

            claude_tests = subprocess.run(
                [str(isolated_bin / "python3"), "-m", "unittest", "tests.runtime_preview.test_claude", "-v"],
                cwd=ROOT,
                env=isolated_environment,
                text=True,
                capture_output=True,
            )
            self.assertEqual(claude_tests.returncode, 0, claude_tests.stdout + claude_tests.stderr)

    def test_cli_requires_arguments_and_builds_only_an_explicit_destination(self):
        """Would fail if a no-argument run installed implicitly or a valid CLI request did nothing."""
        no_arguments = subprocess.run(
            [sys.executable, str(SCRIPT)],
            cwd=ROOT,
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(no_arguments.returncode, 0)

        with TemporaryDirectory() as temporary:
            destination = Path(temporary) / "packages/build-1/codex-preview"
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--host",
                    "codex",
                    "--destination",
                    str(destination),
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(destination))
            self.assertTrue((destination / "adapters/codex/preview/.codex-plugin/plugin.json").is_file())

    def test_explicit_package_rehearsal_preserves_projects_and_legacy_claude(self):
        """Would fail if package enablement/removal rewrote config, instructions, hooks, or legacy behavior."""
        build_package = load_packager().build_package
        with TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            for host in ("claude-code", "codex"):
                with self.subTest(host=host):
                    project = temporary_path / (host + "-project")
                    project.mkdir()
                    preserved = {
                        "host-settings.json": json.dumps({
                            "unrelated": {"enabled": True},
                            "hooks": ["existing-project-hook"],
                        }, sort_keys=True) + "\n",
                        "CLAUDE.md": "# Existing Claude instructions\n",
                        "AGENTS.md": "# Existing Codex instructions\n",
                        "ticket-state.json": '{"ticket":"UNCHANGED"}\n',
                    }
                    for relative, content in preserved.items():
                        (project / relative).write_text(content, encoding="utf-8")
                    before = {
                        relative: (project / relative).read_bytes()
                        for relative in preserved
                    }

                    package = build_package(host, project / "runtime-preview-package")
                    after_install = {
                        relative: (project / relative).read_bytes()
                        for relative in preserved
                    }
                    self.assertEqual(after_install, before)
                    for _attempt in range(2):
                        with self.assertRaises(FileExistsError):
                            build_package(host, package)
                    self.assertEqual(
                        json.loads((project / "host-settings.json").read_text(encoding="utf-8"))["hooks"],
                        ["existing-project-hook"],
                    )

                    shutil.rmtree(package)
                    self.assertFalse(package.exists())
                    after_removal = {
                        relative: (project / relative).read_bytes()
                        for relative in preserved
                    }
                    self.assertEqual(after_removal, before)

        legacy_checks = (
            [sys.executable, "-m", "unittest", "tests.runtime_preview.test_legacy", "-v"],
            ["bash", "tests/test_model_resolver.sh"],
            ["bash", "tests/test_story_lib.sh"],
        )
        for command in legacy_checks:
            with self.subTest(command=command):
                result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
