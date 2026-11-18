#!/usr/bin/env python3
# Tests for mem-sample. Run: python3 .local/bin/mem-sample.test.py
#
# What matters: a sample is one JSON line a collector can read, built from a
# /proc tree; no secret-shaped argument and no environment reaches it; the
# file on disk never passes twice the cap; a machine without /proc is a quiet
# no-op. Each test builds a throwaway /proc under a temp dir.
import datetime
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import stat
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "mem-sample"
SID = "eabdc2b3-d030-4259-9003-483adce0b4da"
NOW = datetime.datetime(2026, 11, 17, 13, 22, 5, tzinfo=datetime.timezone.utc)


def load_script():
    loader = importlib.machinery.SourceFileLoader("mem_sample", str(SCRIPT))
    spec = importlib.util.spec_from_loader("mem_sample", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


ms = load_script()


class MemSampleTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.old_env = dict(os.environ)
        os.environ["HOME"] = str(self.home)
        self.proc = self.tmp / "proc"
        (self.proc / "pressure").mkdir(parents=True)
        (self.proc / "meminfo").write_text(
            "MemTotal:       14722716 kB\nMemFree:          200000 kB\nMemAvailable:    1024000 kB\n"
            "SwapTotal:       4194304 kB\nSwapFree:              0 kB\n")
        (self.proc / "pressure" / "memory").write_text(
            "some avg10=61.20 avg60=40.05 avg300=12.00 total=18998924\n"
            "full avg10=55.00 avg60=33.30 avg300=10.00 total=16583156\n")
        (self.proc / "loadavg").write_text("18.50 9.00 4.00 3/900 4242\n")
        (self.proc / "uptime").write_text("1000.00 5000.00\n")

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self.old_env)
        shutil.rmtree(self.tmp)

    def add(self, pid, argv, rss_pages, start_ticks=0, comm="x", cwd=None, title=None):
        d = self.proc / str(pid)
        d.mkdir()
        fields = ["S"] + ["0"] * 18 + [str(start_ticks), "0", str(rss_pages)] + ["0"] * 10
        (d / "stat").write_text(f"{pid} ({comm}) " + " ".join(fields) + "\n")
        (d / "cmdline").write_bytes(title.encode() if title else b"".join(a.encode() + b"\0" for a in argv))
        (d / "environ").write_bytes(b"GH_TOKEN=ghp_environmentsecret0000000000000000\0")
        if cwd:
            os.symlink(cwd, d / "cwd")

    def sample(self):
        return ms.sample(self.proc, now=NOW, tick=100, page=4096)

    def test_totals_pressure_and_load(self):
        s = self.sample()
        self.assertEqual(s["ts"], "2026-11-17T13:22:05Z")
        self.assertEqual(s["mem_kb"], {"total": 14722716, "available": 1024000,
                                       "swap_total": 4194304, "swap_free": 0})
        self.assertEqual(s["psi"], {"some": {"avg10": 61.2, "avg60": 40.05},
                                    "full": {"avg10": 55.0, "avg60": 33.3}})
        self.assertEqual(s["load1"], 18.5)

    def test_no_pressure_file_is_null(self):
        shutil.rmtree(self.proc / "pressure")
        self.assertIsNone(self.sample()["psi"])

    def test_no_proc_is_a_quiet_no_op(self):
        self.assertIsNone(ms.sample(self.tmp / "absent"))

    def test_groups_count_and_sum(self):
        mb = 256  # pages in one MB
        self.add(1, ["/home/u/.local/share/claude/versions/2.1.319", "--session-id", SID], 400 * mb, comm="2.1.319")
        self.add(2, ["/home/u/.claude/remote/ccd-cli/2.1.325-1ef0", "--verbose"], 300 * mb, comm="2.1.325-1ef0")
        self.add(3, [], 100 * mb, title="claude bg-spare --bg-spare /tmp/x.sock")
        self.add(4, ["/opt/chrome-headless-shell", "--headless"], 50 * mb)
        self.add(5, ["node", "vite"], 30 * mb)
        self.add(6, ["npm exec vitest"], 20 * mb)
        self.add(7, ["java", "-Xmx1g"], 10 * mb)
        self.add(8, ["/usr/bin/python3", "-m", "http.server"], 5 * mb)
        self.add(9, ["/sbin/init"], 2 * mb)
        self.add(11, ["claude bg-spare", "--bg-spare", "/tmp/x.sock"], 100 * mb)
        self.add(10, [], 0, comm="kthreadd")
        s = self.sample()
        self.assertEqual(s["procs"], 10)
        self.assertEqual(s["groups"], {
            "claude": {"n": 4, "rss_mb": 900}, "chrome-headless": {"n": 1, "rss_mb": 50},
            "node": {"n": 2, "rss_mb": 50}, "java": {"n": 1, "rss_mb": 10},
            "python": {"n": 1, "rss_mb": 5}, "other": {"n": 1, "rss_mb": 2}})

    def test_top_ten_by_rss_with_age(self):
        for pid in range(1, 15):
            self.add(pid, ["sleep", str(pid)], pid * 256, start_ticks=pid * 100)
        top = self.sample()["top"]
        self.assertEqual([r["pid"] for r in top], list(range(14, 4, -1)))
        self.assertEqual(top[0], {"pid": 14, "rss_mb": 14, "age_s": 986, "group": "other", "cmd": "sleep 14"})

    def test_comm_with_spaces_and_parens(self):
        self.add(1, [], 256, comm="a (b) c")
        self.assertEqual(self.sample()["top"][0]["cmd"], "[a (b) c]")

    def test_claude_row_keeps_session_and_cwd(self):
        self.add(1, ["claude", "--resume=" + SID, "a prompt with a secret hunter2"], 256,
                 cwd=str(self.home / "proj"))
        row = self.sample()["top"][0]
        self.assertEqual(row["session"], SID)
        self.assertEqual(row["cwd"], "~/proj")
        self.assertEqual(row["cmd"], f"claude --resume={SID} [30 chars]")

    def test_environment_is_never_read(self):
        self.add(1, ["node", "server.js"], 256)
        self.assertNotIn("environmentsecret", json.dumps(self.sample()))

    def test_secret_shaped_arguments_are_replaced(self):
        cases = [
            (["curl", "--token", "abc"], "curl --token [redacted]"),
            (["aws", "configure", "set", "aws_secret_access_key", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"],
             "aws configure set aws_secret_access_key [redacted]"),
            (["x", "/etc/keys/dir", "plain"], "x /etc/keys/dir plain"),
            (["curl", "--password=hunter2"], "curl --password=[redacted]"),
            (["srv", "--token-file", "/run/t.abc"], "srv --token-file [redacted]"),
            (["curl", "-H", "Authorization: Bearer abc"], "curl -H [25 chars]"),
            (["gh", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"], "gh [redacted]"),
            (["env", "GH_TOKEN=abc", "gh"], "env GH_TOKEN=[redacted] gh"),
            (["git", "clone", "https://me:pw@example.invalid/r.git"],
             "git clone https://[redacted]@example.invalid/r.git"),
            (["x", "/srv/87375cc7c944eb9d45c8d9267edc70a4b4827961/server"], "x /srv/[redacted]/server"),
            (["x", "--id", SID], f"x --id {SID}"),
            (["x", "/home/u/proj/.claude/worktrees/unlawful-displays-212/bin"],
             "x /home/u/proj/.claude/worktrees/unlawful-displays-212/bin"),
        ]
        for argv, want in cases:
            with self.subTest(argv=argv):
                self.assertEqual(ms.command(argv), want)

    def test_command_is_short_and_keeps_few_arguments(self):
        self.assertEqual(ms.command(["a"] + [str(i) for i in range(20)]), "a 0 1 2 3 4 5 ...")
        long = ms.command(["/bin/" + "p" * 200, "x"])
        self.assertEqual(len(long), 120)
        self.assertTrue(long.endswith("..."))

    def test_secret_past_the_kept_arguments_is_dropped(self):
        self.assertNotIn("hunter2", ms.command(["a"] + ["x"] * 10 + ["--password", "hunter2"]))

    def test_append_is_one_private_line(self):
        path = ms.state_file()
        ms.append(path, json.dumps(self.sample()))
        ms.append(path, json.dumps(self.sample()))
        lines = path.read_text().splitlines()
        self.assertEqual(len(lines), 2)
        self.assertEqual(json.loads(lines[1])["v"], 1)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)

    def test_rotation_keeps_two_files_under_the_cap(self):
        path = self.tmp / "s.jsonl"
        line = "x" * 99
        for _ in range(100):
            ms.append(path, line, cap=1000)
        old = path.with_name("s.jsonl.1")
        self.assertLessEqual(path.stat().st_size, 1000)
        self.assertLessEqual(old.stat().st_size, 1000)
        self.assertEqual(sorted(p.name for p in self.tmp.glob("s.jsonl*")), ["s.jsonl", "s.jsonl.1"])

    def test_cli_prints_one_json_line_and_refuses_unknown_arguments(self):
        out = io.StringIO()
        with redirect_stdout(out):
            rc = ms.main(["--print"])
        self.assertEqual(rc, 0)
        if out.getvalue():  # empty where the test machine has no /proc
            self.assertEqual(len(out.getvalue().splitlines()), 1)
            self.assertIn("mem_kb", json.loads(out.getvalue()))
        self.assertFalse(ms.state_file().exists())
        with redirect_stderr(io.StringIO()):
            self.assertEqual(ms.main(["--bogus"]), 2)


if __name__ == "__main__":
    unittest.main()
