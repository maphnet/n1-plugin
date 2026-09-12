"""Filesystem tests for relocatable runtime-preview packages."""

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/package-review-preview.py"
GUIDE = ROOT / "references/runtime-review-preview.md"
CODEX_AGENT_NAMES = (
    "n1_runtime_code_reviewer",
    "n1_runtime_security_reviewer",
    "n1_runtime_review_verifier",
)


def load_packager():
    spec = importlib.util.spec_from_file_location("package_review_preview", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def snapshot_tree(root: Path):
    """Return every directory, file byte, and symlink target below root."""
    snapshot = {}
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            snapshot[relative] = ("symlink", os.readlink(path))
        elif path.is_dir():
            snapshot[relative] = ("directory", None)
        else:
            snapshot[relative] = ("file", path.read_bytes())
    return snapshot


def snapshot_file_state(root: Path):
    """Return complete file and symlink state, ignoring harmless empty cache directories."""
    return {
        relative: value
        for relative, value in snapshot_tree(root).items()
        if value[0] != "directory"
    }


class DisposableCodexHost:
    """A native Codex plugin/config rehearsal isolated from user configuration."""

    MARKETPLACE_NAME = "n1-review-runtime"
    AGENT_BLOCK_BEGIN = "# n1-review-runtime agents: begin"
    AGENT_BLOCK_END = "# n1-review-runtime agents: end"

    def __init__(self, root: Path, package: Path):
        self.root = root
        self.package = package
        self.codex = shutil.which("codex")
        if self.codex is None:
            raise unittest.SkipTest("installed Codex CLI is required for native package rehearsal")
        self.codex_home = root / "codex-home"
        self.user_home = root / "user-home"
        self.marketplace = root / "n1-runtime-marketplace"
        self.codex_home.mkdir()
        self.user_home.mkdir()
        (self.marketplace / ".agents/plugins").mkdir(parents=True)
        (self.marketplace / "plugins").mkdir()
        (self.marketplace / "plugins/runtime-review").symlink_to(
            package / "adapters/codex/preview",
            target_is_directory=True,
        )
        marketplace_manifest = {
            "name": self.MARKETPLACE_NAME,
            "interface": {"displayName": "N1 Review Preview Test"},
            "plugins": [{
                "name": "runtime-review",
                "source": {
                    "source": "local",
                    "path": "./plugins/runtime-review",
                },
                "policy": {
                    "installation": "AVAILABLE",
                    "authentication": "ON_INSTALL",
                },
                "category": "Productivity",
            }],
        }
        (self.marketplace / ".agents/plugins/marketplace.json").write_text(
            json.dumps(marketplace_manifest, indent=2) + "\n",
            encoding="utf-8",
        )
        existing_agent = self.codex_home / "existing-agent.toml"
        existing_agent.write_text('model = "gpt-5"\n', encoding="utf-8")
        (self.codex_home / "hooks").mkdir()
        (self.codex_home / "hooks/unrelated.json").write_text(
            '{"hooks":["existing-hook"]}\n',
            encoding="utf-8",
        )
        self.baseline_config = (
            'model = "gpt-5"\n\n'
            '[agents.existing_reviewer]\n'
            'description = "Preserved unrelated reviewer"\n'
            f"config_file = {json.dumps(str(existing_agent))}\n"
        )
        self.config = self.codex_home / "config.toml"
        self.config.write_text(self.baseline_config, encoding="utf-8")
        self.environment = os.environ.copy()
        self.environment.update({
            "CODEX_HOME": str(self.codex_home),
            "HOME": str(self.user_home),
            "N1_HOME": str(root / "n1-home"),
        })

    def run(self, *arguments: str):
        result = subprocess.run(
            [self.codex, "plugin", *arguments],
            cwd=self.root,
            env=self.environment,
            text=True,
            capture_output=True,
        )
        self._last_result = result
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)
        return result

    def install(self):
        self.run("marketplace", "add", str(self.marketplace), "--json")
        self.run("add", f"runtime-review@{self.MARKETPLACE_NAME}", "--json")
        current = self.config.read_text(encoding="utf-8")
        if self.AGENT_BLOCK_BEGIN not in current:
            entries = [self.AGENT_BLOCK_BEGIN]
            for name in CODEX_AGENT_NAMES:
                profile = self.package / f"adapters/codex/preview/agents/{name}.toml"
                entries.extend((f"[agents.{name}]", f"config_file = {json.dumps(str(profile))}", ""))
            entries.append(self.AGENT_BLOCK_END)
            self.config.write_text(current + "\n" + "\n".join(entries) + "\n", encoding="utf-8")

    def remove(self):
        self.run("remove", f"runtime-review@{self.MARKETPLACE_NAME}", "--json")
        self.run("marketplace", "remove", self.MARKETPLACE_NAME, "--json")
        current = self.config.read_text(encoding="utf-8")
        before, marker, remainder = current.partition(self.AGENT_BLOCK_BEGIN)
        if marker:
            _managed, end, after = remainder.partition(self.AGENT_BLOCK_END)
            if not end:
                raise AssertionError("unterminated preview agent configuration")
            current = before.removesuffix("\n") + after.removeprefix("\n")
        self.config.write_text(current, encoding="utf-8")

    def installed_plugins(self):
        result = self.run("list", "--json")
        return json.loads(result.stdout)

    def registered_marketplaces(self):
        result = self.run("marketplace", "list", "--json")
        return json.loads(result.stdout)


class PackagingTests(unittest.TestCase):
    def test_claude_package_preserves_the_existing_n1_plugin_and_adds_runtime_resources(self):
        """Would fail if assembly created a second identity or omitted existing N1 commands."""
        build_package = load_packager().build_package
        with TemporaryDirectory() as temporary:
            package = build_package("claude-code", Path(temporary) / "preview")

            self.assertTrue((package / "lib/runtime-review.sh").is_file())
            manifest = json.loads((package / ".claude-plugin/plugin.json").read_text())
            self.assertEqual(manifest["name"], "n1")
            self.assertEqual(manifest["version"], "3.0.0")
            self.assertFalse((package / "adapters/claude-code/preview/.claude-plugin").exists())
            for required_path in (
                "agents/developer.md", "agents/n1-runtime-code-reviewer.md",
                "defaults/estimation.json", "references/ci-detection.md",
                "hooks/hooks.json", "skills/n1-review/SKILL.md",
                "skills/n1-review-runtime/SKILL.md", "scripts/benchmark.py",
                "README.md", "pipeline.json",
            ):
                with self.subTest(required_path=required_path):
                    self.assertTrue((package / required_path).is_file())
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
            (source / "adapters/pi/preview").mkdir(parents=True)
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
                    packager.build_package("pi", destination)
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

    def test_codex_docs_define_the_native_package_lifecycle(self):
        """Would fail if Codex enablement/removal named no executable native package boundary."""
        guide = GUIDE.read_text(encoding="utf-8")
        self.assertIn("codex plugin marketplace add /absolute/n1-runtime-marketplace", guide)
        self.assertIn("codex plugin add runtime-review@n1-review-runtime", guide)
        self.assertIn("codex plugin remove runtime-review@n1-review-runtime", guide)
        self.assertIn("codex plugin marketplace remove n1-review-runtime", guide)

    def test_claude_docs_use_the_installed_n1_command_namespace(self):
        """Would fail if Claude documentation omitted the root plugin command namespace."""
        guide = GUIDE.read_text(encoding="utf-8")
        claude_section = guide.split("## Enable and check Claude Code", 1)[1].split(
            "## Enable and check Codex", 1
        )[0]
        self.assertIn("/n1:n1-review-runtime owner/repo#123", claude_section)
        self.assertNotIn("/n1-review-runtime owner/repo#123", claude_section)

    def test_codex_rehearsal_changes_disposable_opt_in_state(self):
        """Would fail without native, repeatable Codex enablement and narrow rollback."""
        build_package = load_packager().build_package
        with TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            protected = temporary_path / "protected-state"
            project = protected / "project"
            evidence = protected / "n1-home/scratch/reviews/run-1"
            project.mkdir(parents=True)
            evidence.mkdir(parents=True)
            (project / "AGENTS.md").write_text("# Existing instructions\n", encoding="utf-8")
            (project / "host-settings.json").write_text(
                '{"hooks":["existing-project-hook"],"unrelated":true}\n',
                encoding="utf-8",
            )
            (project / "ticket-state.json").write_text('{"ticket":"UNCHANGED"}\n', encoding="utf-8")
            (evidence / "capability-report.json").write_text(
                '{"status":"unverified"}\n',
                encoding="utf-8",
            )
            protected_baseline = snapshot_tree(protected)

            package = build_package("codex", temporary_path / "runtime-preview-package")
            package_baseline = snapshot_tree(package)
            host = DisposableCodexHost(temporary_path, package)
            config_baseline = snapshot_file_state(host.codex_home)

            host.install()
            host.install()

            installed_config = host.config.read_text(encoding="utf-8")
            self.assertNotEqual(snapshot_file_state(host.codex_home), config_baseline)
            self.assertEqual(installed_config.count(host.AGENT_BLOCK_BEGIN), 1)
            self.assertEqual(installed_config.count(host.AGENT_BLOCK_END), 1)
            for name in CODEX_AGENT_NAMES:
                self.assertEqual(installed_config.count(f"[agents.{name}]"), 1)
            self.assertIn("[agents.existing_reviewer]", installed_config)
            self.assertEqual(
                (host.codex_home / "hooks/unrelated.json").read_bytes(),
                b'{"hooks":["existing-hook"]}\n',
            )
            self.assertEqual(snapshot_tree(protected), protected_baseline)
            self.assertEqual(snapshot_tree(package), package_baseline)

            installed = host.installed_plugins()
            registrations = [
                entry
                for entry in installed["installed"]
                if entry["pluginId"] == f"runtime-review@{host.MARKETPLACE_NAME}"
            ]
            self.assertEqual(len(registrations), 1, installed)
            self.assertTrue(registrations[0]["enabled"])
            marketplaces = host.registered_marketplaces()
            self.assertEqual(
                sum(
                    entry["name"] == host.MARKETPLACE_NAME
                    for entry in marketplaces["marketplaces"]
                ),
                1,
                marketplaces,
            )
            hook_registrations = list(host.codex_home.rglob("hooks.json"))
            self.assertEqual(len(hook_registrations), 1, hook_registrations)
            self.assertEqual(
                json.loads(hook_registrations[0].read_text(encoding="utf-8")),
                {"hooks": {}},
            )

            host.remove()

            self.assertEqual(snapshot_file_state(host.codex_home), config_baseline)
            self.assertEqual(host.config.read_text(encoding="utf-8"), host.baseline_config)
            self.assertEqual(snapshot_tree(protected), protected_baseline)
            self.assertEqual(snapshot_tree(package), package_baseline)

    def test_package_build_removal_preserves_project_and_legacy_claude(self):
        """Would fail if package assembly/removal rewrote project state or legacy behavior."""
        build_package = load_packager().build_package
        with TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            project = temporary_path / "claude-code-project"
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
            before = {relative: (project / relative).read_bytes() for relative in preserved}

            package = build_package("claude-code", project / "runtime-preview-package")
            after_build = {relative: (project / relative).read_bytes() for relative in preserved}
            self.assertEqual(after_build, before)
            with self.assertRaises(FileExistsError):
                build_package("claude-code", package)

            shutil.rmtree(package)
            self.assertFalse(package.exists())
            after_removal = {relative: (project / relative).read_bytes() for relative in preserved}
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
