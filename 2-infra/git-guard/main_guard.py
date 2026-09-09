#!/usr/bin/env python3
"""main push 事后检查；只写异常 Issue，不 revert、不设置 required checks。"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ZERO = "0" * 40
SHA = re.compile(r"[0-9a-f]{40}")


class GuardError(RuntimeError):
    pass


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True, check=False)
    if result.returncode:
        raise GuardError(f"无法读取 Git 事实：git {args[0]}")
    return result.stdout


class GitHub:
    def __init__(self, repo):
        self.repo = repo

    def api(self, path, *, payload=None, paginate=False):
        cmd = ["gh", "api", f"repos/{self.repo}/{path}", "-H", "Accept: application/vnd.github+json"]
        if paginate:
            cmd += ["--paginate", "--slurp"]
        if payload is not None:
            cmd += ["--method", "POST", "--input", "-"]
        result = subprocess.run(
            cmd, input=None if payload is None else json.dumps(payload),
            capture_output=True, text=True, check=False,
        )
        if result.returncode:
            # 不把失败当成无 PR / 无 Issue；权限不足也必须让 Action 红灯。
            raise GuardError(f"GitHub API 失败：{path.split('?')[0]}（检查权限或网络；未放行）")
        try:
            data = json.loads(result.stdout)
        except ValueError as exc:
            raise GuardError("GitHub API 返回无效 JSON，未放行") from exc
        if paginate:
            if not isinstance(data, list) or any(not isinstance(page, list) for page in data):
                raise GuardError("GitHub 分页结果无效，未放行")
            return [row for page in data for row in page]
        return data


def contract_approve(sha):
    """和稳定 contract_approve 的提交格式对齐；路径与标题必须同时符合。"""
    subject = git("show", "-s", "--format=%s", sha).decode().strip()
    match = re.fullmatch(r"docs\(meta\): (?:批准|修订)任务契约 #([1-9][0-9]*)", subject)
    if not match:
        return False
    parents = git("rev-list", "--parents", "-n", "1", sha).split()
    if len(parents) != 2:
        return False
    prefix = f"0-meta/tasks/{match[1]}/"
    paths = git(
        "diff-tree", "--no-commit-id", "--no-renames", "--name-only", "-z", "-r", sha,
    ).decode().split("\0")
    paths = [path for path in paths if path]
    allowed = {prefix + "contract.json", prefix + "contract.md"}
    if not paths or not set(paths) <= allowed:
        return False
    # 删除、坏 JSON 或 Issue 号不一致不是 approve 的产物。
    entries = git("ls-tree", "-r", "--format=%(objectmode) %(path)", sha, "--", prefix).decode().splitlines()
    if not {"100644 " + path for path in allowed} <= set(entries):
        return False
    try:
        contract = json.loads(git("show", f"{sha}:{prefix}contract.json"))
    except (ValueError, GuardError):
        return False
    return (
        isinstance(contract, dict)
        and contract.get("schema_version") == "task-contract/v1"
        and contract.get("issue") == "#" + match[1]
        and all(isinstance(contract.get(key), list) and contract[key]
                for key in ("requirements", "acceptances", "scope"))
    )


def merged_pr(api, sha, branch, sleep=time.sleep):
    # push 事件可能早于 PR 的 merged 状态可见；短暂重读后仍无证据才报告。
    for attempt in range(3):
        rows = api.api(f"commits/{sha}/pulls?per_page=100", paginate=True)
        if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
            raise GuardError("关联 PR 响应无效，未放行")
        for row in rows:
            base = row.get("base") or {}
            base_repo = base.get("repo") or {}
            if (row.get("state") == "closed" and row.get("merged_at")
                    and row.get("merge_commit_sha") == sha
                    and base.get("ref") == branch and base_repo.get("full_name") == api.repo):
                return True
        if attempt < 2:
            sleep(2)
    return False


def report(api, incidents):
    # list 包括 closed，用直接 REST 分页而非有索引延迟的搜索；不覆盖人工内容。
    rows = api.api("issues?state=all&per_page=100", paginate=True)
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise GuardError("Issue 查重响应无效，未创建")
    for sha, reason in incidents:
        marker = f"<!-- main-guard:{sha} -->"
        existing = [row for row in rows if not row.get("pull_request")
                    and marker in (row.get("body") or "").splitlines()]
        if existing:
            print(f"main-guard: {sha} 已报告，不重复创建")
            continue
        created = api.api("issues", payload={
            "title": f"bug(infra): main tripwire 检测到未受控提交 {sha[:12]}",
            "body": (f"{marker}\n\nmain 出现缺少受控来源证据的变更。\n\n"
                     f"提交：https://github.com/{api.repo}/commit/{sha}\n\n"
                     f"原因：{reason}\n\n请人工核对；本 Action 未 revert，也不提供服务端拦截。"),
            "labels": ["bug"],
        })
        if not isinstance(created, dict) or not created.get("number"):
            raise GuardError("Issue 创建结果未确认；重跑先查重，不盲目重建")
        rows.append(created)
        print(f"main-guard: {sha} 已创建异常 Issue #{created['number']}")


def inspect(event, api, branch="main", sleep=time.sleep):
    if event.get("repository", {}).get("full_name") != api.repo:
        raise GuardError("事件仓库与运行仓库不一致")
    if event.get("ref") != "refs/heads/" + branch:
        raise GuardError("事件不是待检查的 main 分支")
    before, after = event.get("before", ""), event.get("after", "")
    if not SHA.fullmatch(before) or not SHA.fullmatch(after):
        raise GuardError("事件缺少有效 before/after SHA")
    if after == ZERO:
        incidents = [(before, "main 被删除")]
    elif event.get("forced"):
        incidents = [(after, "main 被强制改写")]
    else:
        if before == ZERO:
            commits = [after]
        else:
            # 不接受丢失 before 对象、浅历史或非祖先被误判成空区间。
            git("merge-base", "--is-ancestor", before, after)
            commits = git("rev-list", "--first-parent", "--reverse", f"{before}..{after}").decode().split()
        incidents = []
        for sha in commits:
            if contract_approve(sha) or merged_pr(api, sha, branch, sleep):
                continue
            incidents.append((sha, "既非已合并 PR 的结果，也非受控契约批准提交"))
    if incidents:
        report(api, incidents)
        return 1
    print("main-guard: main 提交来源检查通过")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH"))
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--branch", default="main", help="生产固定 main；sandbox 可传 e2e/*")
    args = parser.parse_args()
    if not args.event or not args.repo or not re.fullmatch(r"[\w.-]+/[\w.-]+", args.repo):
        parser.error("需要 GitHub push event 文件与 owner/repo")
    if args.branch != "main" and not (args.repo == "qiaoen12/g-lite-harness" and args.branch.startswith("e2e/")):
        parser.error("main 之外只允许 g-lite-harness 的 e2e/*")
    try:
        event = json.loads(Path(args.event).read_text())
        return inspect(event, GitHub(args.repo), args.branch)
    except (GuardError, OSError, ValueError) as exc:
        print(f"main-guard: fail-closed：{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
