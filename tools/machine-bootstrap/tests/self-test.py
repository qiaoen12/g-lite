#!/usr/bin/env python3
from importlib.machinery import SourceFileLoader
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "role-exec"
loader = SourceFileLoader("role_exec", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
role = importlib.util.module_from_spec(spec)
spec.loader.exec_module(role)


class RoleEntryTests(unittest.TestCase):
    def test_bad_role_and_missing_command(self):
        for args in ([], ["human", "check", "--repo", "o/r"], ["developer", "--"]):
            with self.assertRaises(role.Blocked):
                role.parse_args(args)

    def test_role_actors_are_distinct(self):
        self.assertEqual(role.EXPECTED_ACTORS["developer"], "g-lite-developer[bot]")
        self.assertEqual(role.EXPECTED_ACTORS["reviewer"], "g-lite-reviewer[bot]")
        self.assertNotEqual(role.EXPECTED_ACTORS["developer"],
                            role.EXPECTED_ACTORS["reviewer"])

    def test_actor_mismatch_and_repo_access_fail_closed(self):
        viewer = {"data": {"viewer": {"login": "qiaoen12"}}}
        with patch.object(role, "api_json", return_value=viewer) as api:
            with self.assertRaises(role.Blocked):
                role.verify_role("developer", "o/r", "token")
            api.assert_called_once()

        viewer["data"]["viewer"]["login"] = "g-lite-developer[bot]"
        with patch.object(role, "api_json", side_effect=[viewer, role.Blocked("no access")]):
            with self.assertRaises(role.Blocked):
                role.verify_role("developer", "o/r", "token")

    def test_machine_bootstrap_environment_drops_human_identity(self):
        source = {
            "GH_TOKEN": "human",
            "GITHUB_TOKEN": "human",
            "GH_CONFIG_DIR": "human-config",
            "GITHUB_APP_ROLE": "reviewer",
            "G_LITE_DEVELOPER_PRIVATE_KEY_FILE": "secret-path",
            "GIT_CONFIG_KEY_0": "url.ssh://git@github.com/.insteadOf",
            "PATH": "/usr/bin",
            "HOME": "/tmp/home",
        }
        env = role.clean_environment(source)
        self.assertEqual(env["PATH"], "/usr/bin")
        self.assertEqual(env["HOME"], "/tmp/home")
        self.assertTrue(all(key not in env for key in (
            "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR", "GITHUB_APP_ROLE",
            "G_LITE_DEVELOPER_PRIVATE_KEY_FILE", "GIT_CONFIG_KEY_0")))
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertEqual(env["GIT_CONFIG_NOSYSTEM"], "1")

    def test_bootstrap_xtrace_cannot_log_the_installation_token(self):
        token = "role-entry-test-token"
        with tempfile.TemporaryDirectory() as tmp:
            bootstrap, fake_python = Path(tmp) / "app-env.sh", Path(tmp) / "python"
            bootstrap.write_text(
                "set -x\n"
                "GITHUB_APP_ROLE=developer\n"
                f"GH_TOKEN={token}\n"
                "export GITHUB_APP_ROLE GH_TOKEN\n",
                encoding="utf-8",
            )
            fake_python.write_text("#!/bin/sh\nprintf 'fake child reached\\n'\n",
                                   encoding="utf-8")
            fake_python.chmod(0o700)
            result = subprocess.run(
                ["/bin/sh", "-c", role.BOOTSTRAP_SHELL, "role-exec",
                 str(bootstrap), "developer", str(fake_python), "fake-runner.py",
                 "check", "o/r"],
                env=role.clean_environment(), capture_output=True, text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "fake child reached\n")
        self.assertNotIn(token, result.stdout + result.stderr)

    def test_global_https_rewrite_is_ignored_and_local_rewrite_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo, global_config = Path(tmp) / "repo", Path(tmp) / "global"
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "remote", "add", "origin",
                            "https://github.com/o/r.git"], check=True)
            key = "url.ssh://git@github.com/.insteadOf"
            subprocess.run(["git", "config", "--file", str(global_config), key,
                            "https://github.com/"], check=True)
            env = dict(os.environ, GIT_CONFIG_GLOBAL=str(global_config))
            self.assertIsNone(role.verify_effective_origin("o/r", env, cwd=repo))
            subprocess.run(["git", "-C", str(repo), "config", "--local", key,
                            "https://github.com/"], check=True)
            with self.assertRaises(role.Blocked):
                role.verify_effective_origin("o/r", env, cwd=repo)

    def test_child_uses_app_token_in_isolated_gh_and_git_environment(self):
        human = {"GITHUB_TOKEN": "human", "GH_TOKEN": "human",
                 "GH_ENTERPRISE_TOKEN": "human", "GH_CONFIG_DIR": "human-config",
                 "G_LITE_DEVELOPER_PRIVATE_KEY_FILE": "secret-path",
                 "GIT_CONFIG_KEY_0": "url.ssh://git@github.com/.insteadOf"}
        with patch.dict(os.environ, human):
            env = role.child_environment("developer", "app-token", "empty-config", "askpass")
        self.assertEqual(env["GH_TOKEN"], "app-token")
        self.assertEqual(env["GH_CONFIG_DIR"], "empty-config")
        self.assertEqual(env["GIT_ASKPASS"], "askpass")
        self.assertEqual(env["GIT_ALLOW_PROTOCOL"], "https")
        self.assertEqual(env["GIT_CONFIG_GLOBAL"], os.devnull)
        self.assertTrue(all(key not in env for key in (
            "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "G_LITE_DEVELOPER_PRIVATE_KEY_FILE")))
        self.assertEqual(env["GIT_CONFIG_KEY_0"], "credential.helper")

    def test_askpass_answers_only_exact_github_password_prompts(self):
        with tempfile.TemporaryDirectory() as tmp:
            askpass = Path(tmp) / "askpass"
            role.write_askpass(askpass)
            valid = subprocess.run(
                [str(askpass), "Password for 'https://x-access-token@github.com': "],
                env={"GH_TOKEN": "app-token"}, capture_output=True, text=True,
                check=True,
            )
            self.assertEqual(valid.stdout, "app-token\n")
            for prompt in (
                "Password for 'https://other.example': ",
                "Password for 'https://github.com.evil.example': ",
                "Password for 'https://github.com@evil.example': ",
                "Password for 'http://github.com': ",
            ):
                with self.subTest(prompt=prompt):
                    rejected = subprocess.run(
                        [str(askpass), prompt], env={"GH_TOKEN": "app-token"},
                        capture_output=True, text=True,
                    )
                    self.assertNotEqual(rejected.returncode, 0)
                    self.assertEqual(rejected.stdout, "")


if __name__ == "__main__":
    unittest.main()
