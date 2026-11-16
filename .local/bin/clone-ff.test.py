#!/usr/bin/env python3
# Tests for clone-ff. Run: python3 .local/bin/clone-ff.test.py
#
# What matters: a clean clone behind its default branch fast-forwards; every
# other state (feature branch, dirty tracked file, mid-rebase, diverged, an
# untracked file in the way) leaves the clone exactly as it was and says why.
# Each test builds a throwaway origin and a clone at $HOME/<name>; the GraphQL
# query is stubbed by replacing remote_heads with the origin's real head.
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "clone-ff"


def load_script():
    loader = importlib.machinery.SourceFileLoader("clone_ff", str(SCRIPT))
    spec = importlib.util.spec_from_loader("clone_ff", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True).stdout.strip()


def commit(repo, path, text, msg):
    (repo / path).write_text(text)
    git(repo, "add", path)
    git(repo, "commit", "-q", "-m", msg)


class CloneFfTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        (self.home / ".local" / "share").mkdir(parents=True)
        (self.home / ".local" / "share" / "vended-repos.txt").write_text("proj\n")
        self.old_env = dict(os.environ)
        os.environ.update(HOME=str(self.home), GIT_CONFIG_GLOBAL=str(self.tmp / "gitconfig"),
                          GIT_CONFIG_NOSYSTEM="1")
        (self.tmp / "gitconfig").write_text(
            "[user]\n\temail = t@example.invalid\n\tname = t\n[commit]\n\tgpgsign = false\n"
            "[init]\n\tdefaultBranch = main\n")
        self.origin = self.tmp / "origin.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(self.origin)], check=True)
        self.up = self.tmp / "up"
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.up)], check=True, capture_output=True)
        commit(self.up, "a.txt", "one\n", "one")
        git(self.up, "push", "-q", "origin", "main")
        self.clone = self.home / "proj"
        subprocess.run(["git", "clone", "-q", str(self.origin), str(self.clone)], check=True, capture_output=True)
        self.mod = load_script()
        self.mod.EXTRAS = []
        self.mod.origin_slug = lambda repo: ("owner", repo.name)
        self.mod.remote_heads = lambda slugs: (
            {s: ("main", git(self.origin, "rev-parse", "main")) for s in slugs}, 1)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.old_env)
        shutil.rmtree(self.tmp, ignore_errors=True)

    def upstream(self, n=1):
        for i in range(n):
            commit(self.up, "a.txt", f"upstream {i}\n", f"up {i}")
        git(self.up, "push", "-q", "origin", "main")

    def run_ff(self, *argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = self.mod.main(list(argv))
        self.assertEqual(rc, 0)
        status = json.loads((self.home / ".local/state/clone-ff/status.json").read_text())
        return status["clones"]["proj"], buf.getvalue()

    def head(self):
        return git(self.clone, "rev-parse", "HEAD")

    def test_behind_and_clean_fast_forwards(self):
        self.upstream(2)
        st, printed = self.run_ff()
        self.assertEqual(st["state"], "updated")
        self.assertEqual(self.head(), git(self.origin, "rev-parse", "main"))
        self.assertIn("proj: updated: fast-forwarded 2 commit(s)", printed)

    def test_current_clone_is_ok_and_silent(self):
        st, printed = self.run_ff()
        self.assertEqual(st["state"], "ok")
        self.assertEqual(printed, "")

    def test_now_mode_fetches_without_the_query(self):
        self.mod.remote_heads = None  # must not be called
        self.upstream()
        st, _ = self.run_ff("--now")
        self.assertEqual(st["state"], "updated")

    def test_feature_branch_alerts_with_behind_count(self):
        git(self.clone, "switch", "-q", "-c", "feature")
        before = self.head()
        self.upstream(3)
        st, printed = self.run_ff()
        self.assertEqual((st["state"], st["branch"], st["behind"]), ("off-default", "feature", 3))
        self.assertEqual(self.head(), before)
        self.assertIn("proj: off-default: on feature, 3 behind origin/main", printed)

    def test_dirty_tracked_file_and_behind_is_left_alone(self):
        self.upstream()
        before = self.head()
        (self.clone / "a.txt").write_text("my edit\n")
        st, _ = self.run_ff()
        self.assertEqual(st["state"], "dirty-behind")
        self.assertEqual(self.head(), before)
        self.assertEqual((self.clone / "a.txt").read_text(), "my edit\n")

    def test_mid_rebase_is_untouched(self):
        commit(self.clone, "a.txt", "local\n", "local")
        self.upstream()
        git(self.clone, "fetch", "-q")
        r = subprocess.run(["git", "-C", str(self.clone), "rebase", "origin/main"], capture_output=True)
        self.assertNotEqual(r.returncode, 0)  # conflict: rebase stops midway
        before = self.head()
        st, _ = self.run_ff()
        self.assertEqual(st["state"], "mid-op")
        self.assertEqual(self.head(), before)
        self.assertTrue((self.clone / ".git" / "rebase-merge").exists())

    def test_diverged_is_untouched_and_reported(self):
        commit(self.clone, "b.txt", "local\n", "local")
        before = self.head()
        self.upstream()
        st, printed = self.run_ff()
        self.assertEqual((st["state"], st["ahead"], st["behind"]), ("diverged", 1, 1))
        self.assertEqual(self.head(), before)
        self.assertIn("proj: diverged:", printed)

    def test_untracked_file_in_the_way_is_untouched(self):
        commit(self.up, "new.txt", "theirs\n", "add new")
        git(self.up, "push", "-q", "origin", "main")
        (self.clone / "new.txt").write_text("mine\n")
        before = self.head()
        st, _ = self.run_ff()
        self.assertEqual(st["state"], "ff-refused")
        self.assertIn("untracked", st["reason"])
        self.assertEqual(self.head(), before)
        self.assertEqual((self.clone / "new.txt").read_text(), "mine\n")

    def test_worktree_and_missing_dirs_are_skipped(self):
        (self.home / ".local/share/vended-repos.txt").write_text("proj\ngone\nwt\n")
        git(self.clone, "worktree", "add", "-q", str(self.home / "wt"), "-b", "w")
        buf = io.StringIO()
        with redirect_stdout(buf):
            self.assertEqual(self.mod.main([]), 0)
        clones = json.loads((self.home / ".local/state/clone-ff/status.json").read_text())["clones"]
        self.assertEqual(clones["gone"]["state"], "missing")
        self.assertEqual(clones["wt"]["state"], "not-a-clone")

    def test_a_git_timeout_is_one_clone_not_the_run(self):
        real = self.mod.git
        def slow(repo, *args, **kw):
            if args[:1] == ("rev-list",):
                raise subprocess.TimeoutExpired(["git", "--no-optional-locks", "-C", str(repo), *args], 20)
            return real(repo, *args, **kw)
        self.mod.git = slow
        st, printed = self.run_ff()
        self.assertEqual(st["state"], "timeout")
        self.assertIn("proj: timeout: git rev-list timed out after 20s", printed)

    def test_query_failure_fails_the_run(self):
        def boom(slugs):
            raise RuntimeError("GraphQL query failed: offline")
        self.mod.remote_heads = boom
        buf = io.StringIO()
        with redirect_stdout(buf), redirect_stderr(io.StringIO()):
            self.assertEqual(self.mod.main([]), 1)


class QueryParseTest(unittest.TestCase):
    """The parts every other test stubs: the origin URL and the GraphQL answer."""

    def setUp(self):
        self.mod = load_script()

    def test_origin_url_forms(self):
        cases = {
            "https://github.com/o/r": ("o", "r"),
            "https://github.com/o/r.git": ("o", "r"),
            "https://github.com/o/r/": ("o", "r"),
            "git@github.com:o/r.git": ("o", "r"),
            "ssh://git@github.com/o/r.git": ("o", "r"),
            "/srv/git/r.git": None,
        }
        for url, want in cases.items():
            m = self.mod.SLUG_RE.search(url)
            self.assertEqual((m.group(1), m.group(2)) if m else None, want, url)

    def test_remote_heads_reads_partial_answers(self):
        answer = {"data": {"r0": None, "r1": {"name": "r", "defaultBranchRef": {"name": "trunk", "target": {"oid": "abc"}}},
                           "rateLimit": {"cost": 1}}}
        seen = {}

        def fake_run(cmd, **kw):
            seen["query"] = Path(cmd[-1].split("@", 1)[1]).read_text()
            return subprocess.CompletedProcess(cmd, 1, json.dumps(answer), "NOT_FOUND")
        self.mod.subprocess = type("S", (), {"run": staticmethod(fake_run)})
        heads, cost = self.mod.remote_heads([("o", "gone"), ("o", "r")])
        self.assertEqual(heads, {("o", "gone"): None, ("o", "r"): ("trunk", "abc")})
        self.assertEqual(cost, 1)
        self.assertIn('r1: repository(owner: "o", name: "r")', seen["query"])

    def test_remote_heads_without_data_raises(self):
        self.mod.subprocess = type("S", (), {"run": staticmethod(
            lambda cmd, **kw: subprocess.CompletedProcess(cmd, 1, "", "HTTP 401"))})
        with self.assertRaises(RuntimeError):
            self.mod.remote_heads([("o", "r")])


if __name__ == "__main__":
    unittest.main()
