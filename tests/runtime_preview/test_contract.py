import unittest

from lib.runtime_review.contract import validate_request, validate_result


def request():
    return {
        "schemaVersion": 1, "runId": "run-1", "requestId": "request-1",
        "host": "codex", "role": "code-reviewer", "cwd": "/scratch/source",
        "inputs": [{"name": name, "path": "/scratch/inputs/" + name, "required": True}
                   for name in ("diff", "requirements", "conventions")],
        "revision": {"repository": "owner/repo", "baseSha": "a" * 40, "headSha": "b" * 40},
        "modelPolicy": {"mode": "inherit", "provider": None, "model": None, "effort": None},
        "requiredCapabilities": ["readSearchEnforced", "isolatedContext", "lifecycleControl"],
        "timeoutSeconds": 600,
    }


def result(status="completed"):
    value = {
        "schemaVersion": 1, "runId": "run-1", "requestId": "request-1",
        "host": "codex", "role": "code-reviewer",
        "revision": {"repository": "owner/repo", "baseSha": "a" * 40, "headSha": "b" * 40},
        "status": status,
        "evidence": {
            "workerId": "native-handle",
            "requestedModel": None,
            "effectiveModel": None,
            "effectiveModelReason": "The host did not report an effective model.",
            "enforcement": "qualified configuration digest",
            "tokenUsage": None,
        },
        "output": {"findings": [{
            "id": "code-reviewer:1", "title": "Unchecked request", "file": "app.py",
            "line": 12, "claim": "The request is unchecked.", "severity": "High",
            "reasoning": "A caller-controlled request reaches the operation unchecked.",
            "evidence": "app.py:12 accepts the request without validation.",
            "suggestedFix": "Validate the request before the operation.",
        }]},
        "error": None,
    }
    if status != "completed":
        value["output"] = None
        value["error"] = {"code": "adapter-failed", "message": "The adapter failed."}
    return value


def verifier_request():
    value = request()
    value["role"] = "review-verifier"
    value["inputs"] = [{"name": "claims", "path": "/scratch/inputs/claims", "required": True}]
    return value


def verifier_result():
    value = result()
    value["role"] = "review-verifier"
    value["output"] = {"dispositions": [{
        "id": "code-reviewer:1", "verdict": "confirmed",
        "reason": "The source confirms the claim.",
    }]}
    return value


class ContractTests(unittest.TestCase):
    def test_reject_boolean_timeout(self):
        value = request()
        value["timeoutSeconds"] = True
        with self.assertRaisesRegex(ValueError, "timeoutSeconds"):
            validate_request(value)

    def test_reject_unknown_host(self):
        value = request()
        value["host"] = "auto"
        with self.assertRaisesRegex(ValueError, "host"):
            validate_request(value)

    def test_request_enum_and_path_errors(self):
        for key, bad in [("schemaVersion", 2), ("role", "developer"),
                         ("cwd", "relative"), ("runId", "../escape"),
                         ("timeoutSeconds", 0)]:
            with self.subTest(key=key):
                value = request()
                value[key] = bad
                with self.assertRaises(ValueError):
                    validate_request(value)

    def test_request_rejects_boundary_errors(self):
        cases = []
        malformed_sha = request()
        malformed_sha["revision"]["headSha"] = "not-a-sha"
        cases.append(malformed_sha)
        duplicate_input = request()
        duplicate_input["inputs"].append({
            "name": "diff", "path": "/scratch/inputs/other", "required": True,
        })
        cases.append(duplicate_input)
        unexpected = request()
        unexpected["timeOutSeconds"] = 600
        cases.append(unexpected)
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    validate_request(value)

    def test_request_requires_role_specific_inputs(self):
        cases = []
        missing_conventions = request()
        missing_conventions["inputs"] = missing_conventions["inputs"][:-1]
        cases.append(missing_conventions)
        reviewer_arbitrary = request()
        reviewer_arbitrary["inputs"][2]["name"] = "notes"
        cases.append(reviewer_arbitrary)
        optional_diff = request()
        optional_diff["inputs"][0]["required"] = False
        cases.append(optional_diff)
        verifier_arbitrary = verifier_request()
        verifier_arbitrary["inputs"].append({
            "name": "diff", "path": "/scratch/inputs/diff", "required": True,
        })
        cases.append(verifier_arbitrary)
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaisesRegex(ValueError, "inputs"):
                    validate_request(value)

    def test_request_rejects_nonstring_enum_values_with_value_error(self):
        value = request()
        value["role"] = []
        with self.assertRaisesRegex(ValueError, "role"):
            validate_request(value)

    def test_request_defaults_timeout_and_returns_deep_copy(self):
        value = request()
        del value["timeoutSeconds"]
        validated = validate_request(value)
        self.assertEqual(validated["timeoutSeconds"], 600)
        validated["inputs"][0]["name"] = "changed"
        self.assertEqual(value["inputs"][0]["name"], "diff")

    def test_result_rejects_identity_and_revision_mismatches(self):
        for key, bad in [("requestId", "wrong-request"), ("host", "pi")]:
            with self.subTest(key=key):
                value = result()
                value[key] = bad
                with self.assertRaises(ValueError):
                    validate_result(request(), value)
        value = result()
        value["revision"]["headSha"] = "c" * 40
        with self.assertRaisesRegex(ValueError, "revision"):
            validate_result(request(), value)

    def test_result_rejects_malformed_completed_output(self):
        cases = []
        unknown_severity = result()
        unknown_severity["output"]["findings"][0]["severity"] = "Urgent"
        cases.append(unknown_severity)
        duplicate_finding = result()
        duplicate_finding["output"]["findings"].append(dict(
            duplicate_finding["output"]["findings"][0]
        ))
        cases.append(duplicate_finding)
        zero_line = result()
        zero_line["output"]["findings"][0]["line"] = 0
        cases.append(zero_line)
        malformed_output = result()
        del malformed_output["output"]["findings"][0]["suggestedFix"]
        cases.append(malformed_output)
        for value in cases:
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    validate_result(request(), value)

    def test_result_rejects_false_completed_result(self):
        value = result()
        value["error"] = {"code": "adapter-failed", "message": "The adapter failed."}
        with self.assertRaisesRegex(ValueError, "error"):
            validate_result(request(), value)

    def test_noncompleted_result_requires_error_and_null_output(self):
        value = result("failed")
        value["error"] = None
        with self.assertRaisesRegex(ValueError, "error"):
            validate_result(request(), value)
        value = result("failed")
        value["output"] = {"findings": []}
        with self.assertRaisesRegex(ValueError, "output"):
            validate_result(request(), value)

    def test_result_requires_reason_for_missing_model_observations(self):
        value = result()
        value["evidence"]["effectiveModelReason"] = None
        with self.assertRaisesRegex(ValueError, "evidence.effectiveModelReason"):
            validate_result(request(), value)

    def test_result_accepts_shared_evidence_envelope(self):
        self.assertEqual(validate_result(request(), result())["evidence"], result()["evidence"])

    def test_verifier_accepts_dispositions(self):
        self.assertEqual(
            validate_result(verifier_request(), verifier_result())["output"],
            verifier_result()["output"],
        )


if __name__ == "__main__":
    unittest.main()
