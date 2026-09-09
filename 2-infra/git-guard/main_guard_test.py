"""真实 Git 提交 + GitHub API 替身；不向任何远端写入。"""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import main_guard as guard


class FakeGitHub:
    repo = "qiaoen12/g-lite-harness"

    def __init__(self):
        self.pulls = {}
        self.issues = []
        self.calls = []
        self.fail = None
        self.lose_create_ack = False

    def api(self, path, *, payload=None, paginate=False):
        self.calls.append((path, payload, paginate))
        if self.fail and path.startswith(self.fail):
            raise guard.GuardError("API 权限失败")
        if path.startswith("commits/"):
            return self.pulls.get(path.split("/")[1], [])
        if payload is None:
            return copy.deepcopy(self.issues)
        row = {**payload, "number": len(self.issues) + 1}
        self.issues.append(row)
        if self.lose_create_ack:
            raise guard.GuardError("创建已写入但响应丢失")
        return row


class MainGuardTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="main-guard-test-")
        self.addCleanup(self.temp.cleanup)
        cwd = os.getcwd()
        os.chdir(self.temp.name)
        self.addCleanup(os.chdir, cwd)
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
        self.env = patch.dict(os.environ, env, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.before = self.commit("README.md", "baseline", "docs(repo): fixture baseline")
        self.api = FakeGitHub()

    def git(self, *args):
        return guard.git(*args).decode().strip()

    def commit(self, path, content, title):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(content)
        self.git("add", "--", path)
        self.git("commit", "-q", "-m", title)
        return self.git("rev-parse", "HEAD")

    def event(self, sha, **extra):
        return {"repository": {"full_name": self.api.repo}, "ref": "refs/heads/main",
                "before": self.before, "after": sha, **extra}

    def inspect(self, sha, **extra):
        with contextlib.redirect_stdout(io.StringIO()):
            return guard.inspect(self.event(sha, **extra), self.api, sleep=lambda _: None)

    def authorize_pr(self, sha, **extra):
        self.api.pulls[sha] = [{"state": "closed", "merged_at": "2026-09-08T00:00:00Z",
                               "merge_commit_sha": sha,
                               "base": {"ref": "main", "repo": {"full_name": self.api.repo}},
                               **extra}]

    def approve(self, title="docs(meta): 批准任务契约 #30", malformed=False):
        prefix = Path("0-meta/tasks/30")
        prefix.mkdir(parents=True, exist_ok=True)
        (prefix / "contract.md").write_text("<!-- task-contract:v1 -->\nfixture")
        self.git("add", "--", str(prefix / "contract.md"))
        contract = {"schema_version": "task-contract/v1", "issue": "#30",
                    "requirements": [{"id": "R1"}], "acceptances": [{"id": "A1"}],
                    "scope": ["README.md"]}
        return self.commit(str(prefix / "contract.json"),
                           "{}" if malformed else json.dumps(contract), title)

    def test_unauthorized_push_reports_bug_and_fails(self):
        sha = self.commit("README.md", "direct", "docs(repo): direct write")
        self.assertEqual(self.inspect(sha), 1)
        self.assertEqual(len(self.api.issues), 1)
        self.assertEqual(self.api.issues[0]["labels"], ["bug"])
        self.assertIn(sha, self.api.issues[0]["body"])
        self.assertEqual(self.git("rev-parse", "HEAD"), sha)

    def test_squash_result_passes(self):
        sha = self.commit("README.md", "squash", "docs(repo): squash result")
        self.authorize_pr(sha)
        self.assertEqual(self.inspect(sha), 0)
        self.assertFalse(self.api.issues)

    def test_approve_and_revision_pass(self):
        self.approve()
        sha = self.commit("0-meta/tasks/30/contract.md", "revised", "docs(meta): 修订任务契约 #30")
        self.assertEqual(self.inspect(sha), 0)
        self.assertFalse(self.api.calls)

    def test_contract_paths_without_approve_title_rejected(self):
        sha = self.approve(title="docs(meta): arbitrary task edit")
        self.assertEqual(self.inspect(sha), 1)

    def test_approve_title_with_extra_path_rejected(self):
        Path("outside.txt").write_text("outside")
        self.git("add", "outside.txt")
        sha = self.approve()
        self.assertEqual(self.inspect(sha), 1)

    def test_malformed_contract_rejected(self):
        sha = self.approve(malformed=True)
        self.assertEqual(self.inspect(sha), 1)

    def test_approve_delete_is_not_approved(self):
        self.approve()
        self.git("rm", "0-meta/tasks/30/contract.md")
        self.git("commit", "-q", "-m", "docs(meta): 修订任务契约 #30")
        self.assertEqual(self.inspect(self.git("rev-parse", "HEAD")), 1)

    def test_all_commits_in_push_checked(self):
        bad = self.commit("README.md", "bad first", "docs(repo): unreviewed write")
        self.approve()
        tip = self.commit("README.md", "good last", "docs(repo): reviewed write")
        self.authorize_pr(tip)
        self.assertEqual(self.inspect(tip), 1)
        self.assertEqual(len(self.api.issues), 1)
        self.assertIn(bad, self.api.issues[0]["body"])

    def test_closed_issue_dedup_preserves_human_text(self):
        sha = self.commit("README.md", "direct", "docs(repo): direct write")
        self.inspect(sha)
        self.api.issues[0].update(state="closed", body=self.api.issues[0]["body"] + "\n人工补充")
        before = copy.deepcopy(self.api.issues)
        self.assertEqual(self.inspect(sha), 1)
        self.assertEqual(self.api.issues, before)

    def test_associated_pr_is_not_merge_proof(self):
        sha = self.commit("README.md", "direct", "docs(repo): associated only")
        for change in ({"state": "open"}, {"merged_at": None}, {"merge_commit_sha": self.before},
                       {"base": {"ref": "another", "repo": {"full_name": self.api.repo}}},
                       {"base": {"ref": "main", "repo": {"full_name": "other/repo"}}}):
            with self.subTest(change=change):
                self.authorize_pr(sha, **change)
                self.assertFalse(guard.merged_pr(self.api, sha, "main", lambda _: None))

    def test_api_read_and_write_failures_fail_closed(self):
        sha = self.commit("README.md", "direct", "docs(repo): API failure")
        for endpoint in ("commits/", "issues?"):
            with self.subTest(endpoint=endpoint):
                self.api.fail = endpoint
                with self.assertRaises(guard.GuardError):
                    self.inspect(sha)
                self.assertFalse(self.api.issues)
        self.api.fail = None
        with patch.object(self.api, "api", wraps=self.api.api) as api:
            def fail_post(path, **kwargs):
                if kwargs.get("payload"):
                    raise guard.GuardError("issues:write forbidden")
                return FakeGitHub.api(self.api, path, **kwargs)
            api.side_effect = fail_post
            with self.assertRaises(guard.GuardError):
                self.inspect(sha)
        self.assertFalse(self.api.issues)

    def test_lost_create_response_retry_does_not_duplicate(self):
        sha = self.commit("README.md", "direct", "docs(repo): lost response")
        self.api.lose_create_ack = True
        with self.assertRaises(guard.GuardError):
            self.inspect(sha)
        self.api.lose_create_ack = False
        self.assertEqual(self.inspect(sha), 1)
        self.assertEqual(len(self.api.issues), 1)

    def test_delayed_merge_fact_retried(self):
        sha = self.commit("README.md", "merged", "docs(repo): delayed merge")
        def advance(_):
            self.authorize_pr(sha)
        self.assertTrue(guard.merged_pr(self.api, sha, "main", advance))
        self.assertEqual(len(self.api.calls), 2)

    def test_force_push_is_reported_even_if_tip_had_pr(self):
        sha = self.commit("README.md", "merged", "docs(repo): former merge")
        self.authorize_pr(sha)
        self.assertEqual(self.inspect(sha, forced=True), 1)

    def test_missing_before_object_fails_closed(self):
        with self.assertRaises(guard.GuardError):
            self.inspect(self.before, before="1" * 40)
        self.assertFalse(self.api.issues)

    def test_event_target_must_match(self):
        for changes in ({"ref": "refs/heads/other"}, {"repository": {"full_name": "other/repo"}},
                        {"after": "not-a-sha"}):
            with self.subTest(changes=changes), self.assertRaises(guard.GuardError):
                self.inspect(self.before, **changes)
        self.assertFalse(self.api.calls)


class ApiTest(unittest.TestCase):
    @patch("main_guard.subprocess.run")
    def test_pagination_includes_later_pages(self, run):
        run.return_value = subprocess.CompletedProcess([], 0, '[[{"number":1}],[{"number":2}]]')
        api = guard.GitHub("qiaoen12/g-lite-harness")
        self.assertEqual(api.api("issues", paginate=True), [{"number": 1}, {"number": 2}])
        self.assertIn("--paginate", run.call_args.args[0])

    @patch("main_guard.subprocess.run")
    def test_invalid_or_failed_response_is_not_empty(self, run):
        for rc, output in ((1, ""), (0, "invalid"), (0, "{}"), (0, "[{}]")):
            with self.subTest(rc=rc, output=output):
                run.return_value = subprocess.CompletedProcess([], rc, output)
                with self.assertRaises(guard.GuardError):
                    guard.GitHub("qiaoen12/g-lite-harness").api("issues", paginate=True)


if __name__ == "__main__":
    unittest.main()
