import unittest

from lib.runtime_review.models import resolve_policy


class ModelTests(unittest.TestCase):
    def test_rejects_nonstring_host_with_value_error(self):
        with self.assertRaisesRegex(ValueError, "host"):
            resolve_policy({}, [], "code-reviewer")

    def test_legacy_alias_is_not_a_codex_default(self):
        with self.assertRaisesRegex(ValueError, "explicit"):
            resolve_policy({"models": {"code-reviewer": "opus"}}, "codex", "code-reviewer")

    def test_explicit_inherit(self):
        config = {"runtimePreview": {"hosts": {"pi": {"models": {
            "code-reviewer": {"mode": "inherit"}}}}}}
        self.assertEqual(resolve_policy(config, "pi", "code-reviewer"),
                         {"mode": "inherit", "provider": None, "model": None, "effort": None})

    def test_each_new_host_role_requires_its_own_policy(self):
        config = {"runtimePreview": {"hosts": {"codex": {"models": {
            "code-reviewer": {"mode": "inherit"},
        }}}}}
        with self.assertRaisesRegex(ValueError, "explicit"):
            resolve_policy(config, "codex", "security-reviewer")

    def test_explicit_policy_requires_provider_and_model(self):
        config = {"runtimePreview": {"hosts": {"claude-code": {"models": {
            "code-reviewer": {"mode": "explicit", "provider": "anthropic"},
        }}}}}
        with self.assertRaisesRegex(ValueError, "provider"):
            resolve_policy(config, "claude-code", "code-reviewer")

    def test_policy_rejects_mixed_inheritance(self):
        config = {"runtimePreview": {"hosts": {"pi": {"models": {
            "code-reviewer": {"mode": "inherit", "model": "opus"},
        }}}}}
        with self.assertRaisesRegex(ValueError, "inherit"):
            resolve_policy(config, "pi", "code-reviewer")

    def test_policy_returns_a_detached_copy(self):
        config = {"runtimePreview": {"hosts": {"pi": {"models": {
            "code-reviewer": {
                "mode": "explicit", "provider": "openai", "model": "gpt-5", "effort": "high",
            },
        }}}}}
        policy = resolve_policy(config, "pi", "code-reviewer")
        policy["model"] = "changed"
        self.assertEqual(
            config["runtimePreview"]["hosts"]["pi"]["models"]["code-reviewer"]["model"],
            "gpt-5",
        )


if __name__ == "__main__":
    unittest.main()
