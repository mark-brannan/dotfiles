#!/usr/bin/env python3
# Tests for joplin-git-bridge. Run: python3 .local/bin/joplin-git-bridge.test.py
#
# What matters: a clean sync with new files is committed by path with the
# counts in the message; open conflicts are reported and the rest still
# commits; Joplin unreachable or a locked workspace skips quietly; a partial
# run or a busy repo (detached HEAD) never commits; a token in tool output
# never reaches the log. joplin-md-sync itself is a stub driven by env vars.
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "joplin-git-bridge"

STUB = """#!/usr/bin/env python3
import json, os, sys
code = int(os.environ.get("STUB_EXIT", "0"))
root = sys.argv[sys.argv.index("--root") + 1]
if os.environ.get("STUB_WRITE"):
    d = os.path.join(root, "Notebook"); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "note.md"), "w").write("hello\\n")
print(json.dumps({"summary": {"remote_new": 1, "remote_modified": 0, "local_new": 0, "local_modified": 2},
                  "execution": {"applied": 3}, "open_conflicts": 1 if code == 2 else 0}))
sys.stderr.write(os.environ.get("STUB_STDERR", ""))
sys.exit(code)
"""


def load_script():
    loader = importlib.machinery.SourceFileLoader("joplin_git_bridge", str(SCRIPT))
    spec = importlib.util.spec_from_loader("joplin_git_bridge", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=True)


class BridgeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        git(self.repo, "config", "user.email", "t@example.invalid")
        git(self.repo, "config", "user.name", "t")
        git(self.repo, "config", "commit.gpgsign", "false")
        (self.repo / "README").write_text("x\n")
        git(self.repo, "add", "README")
        git(self.repo, "commit", "-q", "-m", "init")
        self.root = self.repo / "joplin"
        self.root.mkdir()
        stub = self.tmp / "joplin-md-sync"
        stub.write_text(STUB)
        stub.chmod(0o755)
        self.mod = load_script()
        self.mod.JMS = str(stub)
        self.mod.STATUS = self.tmp / "state" / "last-run.json"
        self.mod.WORKSPACES = self.tmp / "workspaces"
        self.mod.WORKSPACES.write_text(f"# comment\n{self.root}\n")
        for k in ("STUB_EXIT", "STUB_WRITE", "STUB_STDERR"):
            os.environ.pop(k, None)

    def run_main(self):
        out = io.StringIO()
        with redirect_stdout(out):
            rc = self.mod.main()
        return rc, out.getvalue()

    def head_subject(self):
        return git(self.repo, "log", "-1", "--format=%s").stdout.strip()

    def test_clean_sync_commits_by_path_with_counts(self):
        os.environ["STUB_WRITE"] = "1"
        (self.repo / "unrelated.txt").write_text("not staged\n")
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(self.head_subject(), "joplin: sync joplin: 1 pulled, 2 pushed")
        self.assertIn("committed", out)
        self.assertIn("unrelated.txt", git(self.repo, "status", "--porcelain").stdout)
        status = json.loads(self.mod.STATUS.read_text())
        self.assertIsNotNone(status["workspaces"][0]["commit"])

    def test_conflicts_are_reported_and_the_rest_commits(self):
        os.environ.update(STUB_EXIT="2", STUB_WRITE="1")
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("WARNING", out)
        self.assertIn("1 open conflict(s)", out)
        self.assertIn("conflicts list", out)
        self.assertEqual(self.head_subject(), "joplin: sync joplin: 1 pulled, 2 pushed")

    def test_joplin_unreachable_skips_quietly(self):
        os.environ["STUB_EXIT"] = "4"
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("not reachable", out)
        self.assertEqual(self.head_subject(), "init")

    def test_locked_workspace_skips_quietly(self):
        os.environ["STUB_EXIT"] = "5"
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("locked", out)

    def test_partial_run_never_commits_and_fails(self):
        os.environ.update(STUB_EXIT="6", STUB_WRITE="1")
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("ERROR", out)
        self.assertEqual(self.head_subject(), "init")

    def test_detached_head_syncs_but_does_not_commit(self):
        os.environ["STUB_WRITE"] = "1"
        git(self.repo, "checkout", "-q", "--detach")
        rc, out = self.run_main()
        self.assertEqual(rc, 0)
        self.assertIn("detached HEAD", out)
        self.assertIn("note.md", git(self.repo, "status", "--porcelain", "-uall").stdout)

    def test_token_in_tool_output_is_redacted(self):
        os.environ.update(STUB_EXIT="9", STUB_STDERR="failed GET /notes?token=abc123secret&limit=1")
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertNotIn("abc123secret", out)
        self.assertIn("token=REDACTED", out)

    def test_foreign_staged_file_stays_out_of_the_commit(self):
        (self.repo / "foreign.txt").write_text("staged by someone else\n")
        git(self.repo, "add", "foreign.txt")
        rc, _ = self.run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(self.head_subject(), "init")
        os.environ["STUB_WRITE"] = "1"
        rc, _ = self.run_main()
        self.assertEqual(rc, 0)
        files = git(self.repo, "show", "--name-only", "--format=", "HEAD").stdout.split()
        self.assertEqual(files, ["joplin/Notebook/note.md"])
        self.assertIn("A  foreign.txt", git(self.repo, "status", "--porcelain").stdout)

    def test_deleted_note_is_committed_beside_foreign_staged_file(self):
        os.environ["STUB_WRITE"] = "1"
        self.run_main()
        os.environ.pop("STUB_WRITE")
        (self.root / "Notebook" / "note.md").unlink()
        (self.repo / "foreign.txt").write_text("x\n")
        git(self.repo, "add", "foreign.txt")
        rc, _ = self.run_main()
        self.assertEqual(rc, 0)
        shown = git(self.repo, "show", "--name-status", "--format=", "HEAD").stdout.split()
        self.assertEqual(shown, ["D", "joplin/Notebook/note.md"])
        self.assertIn("A  foreign.txt", git(self.repo, "status", "--porcelain").stdout)

    def test_one_workspace_raising_does_not_stop_the_rest(self):
        os.environ["STUB_WRITE"] = "1"
        real = self.mod.sync_one
        def flaky(root):
            if root.name == "gone":
                raise FileNotFoundError("No such file: joplin-md-sync")
            return real(root)
        self.mod.sync_one = flaky
        self.mod.WORKSPACES.write_text(f"{self.tmp / 'gone'}\n{self.root}\n")
        rc, out = self.run_main()
        self.assertEqual(rc, 1)
        self.assertIn("ERROR: gone", out)
        self.assertEqual(self.head_subject(), "joplin: sync joplin: 1 pulled, 2 pushed")
        self.assertEqual(len(json.loads(self.mod.STATUS.read_text())["workspaces"]), 2)

    def test_missing_workspace_list_is_an_error(self):
        self.mod.WORKSPACES = self.tmp / "absent"
        rc, out = self.run_main()
        self.assertEqual(rc, 2)
        self.assertIn("no workspace list", out)


if __name__ == "__main__":
    unittest.main()
