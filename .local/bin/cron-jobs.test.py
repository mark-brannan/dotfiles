#!/usr/bin/env python3
# Tests for cron-jobs. Run: python3 .local/bin/cron-jobs.test.py
#
# What matters: install rewrites only its own crontab block, keeps every
# foreign line, drops the old dotfiles-sync line, writes nothing when nothing
# changed or the list is malformed, honours host=, and retires a linked
# systemd timer; run logs, records .last, kills a timed-out process group and
# skips while a previous run holds the lock. crontab, hostname and systemctl
# are stubs on PATH, over a temp HOME.
import fcntl
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "cron-jobs"

CRONTAB = """#!/bin/sh
f="$HOME/crontab.txt"
case "$1" in
-l) [ -f "$f" ] || { echo "no crontab for test" >&2; exit 1; }; cat "$f" ;;
-) cat > "$f"; echo x >> "$HOME/crontab.writes" ;;
esac
"""
HOSTNAME = '#!/bin/sh\necho "${FAKE_HOST:-otherbox}"\n'
SYSTEMCTL = """#!/bin/sh
echo "$*" >> "$HOME/systemctl.log"
if [ "$2" = show ]; then
  for a; do u=$a; done
  if grep -qx "$u" "$HOME/units-known" 2>/dev/null; then echo LoadState=loaded; echo ActiveState=active
  else echo LoadState=not-found; echo ActiveState=inactive; fi
fi
exit 0
"""
BEGIN = "# BEGIN jobs (managed by ~/.local/bin/cron-jobs from ~/.config/jobs; edit that file)"

LIST = """# comment
alpha  1m              */5 * * * *  echo alpha
beta   1m  host=BoxA,boxb  0 */6 * * *  echo beta
"""


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.bin = self.home / "stubs"
        self.bin.mkdir()
        for name, body in (("crontab", CRONTAB), ("hostname", HOSTNAME), ("systemctl", SYSTEMCTL)):
            p = self.bin / name
            p.write_text(body)
            p.chmod(0o755)
        (self.home / ".config").mkdir()
        self.write_list(LIST)
        self.env = {"HOME": str(self.home), "PATH": f"{self.bin}:/usr/bin:/bin"}

    def tearDown(self):
        self.tmp.cleanup()

    def write_list(self, text):
        (self.home / ".config" / "jobs").write_text(text)

    def jobs(self, *args, **env):
        return subprocess.run(["python3", str(SCRIPT), *args], capture_output=True, text=True,
                              env={**self.env, **env}, timeout=60)

    def crontab(self):
        return (self.home / "crontab.txt").read_text()

    def set_crontab(self, text):
        (self.home / "crontab.txt").write_text(text)

    def writes(self):
        p = self.home / "crontab.writes"
        return len(p.read_text().splitlines()) if p.exists() else 0


class Install(Base):
    def test_empty_crontab_gets_the_block(self):
        r = self.jobs("install")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = self.crontab().splitlines()
        self.assertEqual(lines[0], BEGIN)
        self.assertIn('*/5 * * * * "$HOME/.local/bin/cron-jobs" run alpha', lines)
        self.assertEqual(lines[-1], "# END jobs")

    def test_second_install_writes_nothing(self):
        self.jobs("install")
        self.jobs("install")
        self.assertEqual(self.writes(), 1)

    def test_foreign_lines_kept_and_block_replaced_in_place(self):
        self.set_crontab(f"MAILTO=x\n0 1 * * * echo before\n{BEGIN}\n1 1 * * * stale run\n# END jobs\n"
                         "0 2 * * * echo after # not ours\n")
        self.jobs("install")
        lines = self.crontab().splitlines()
        self.assertEqual(lines[:3], ["MAILTO=x", "0 1 * * * echo before", BEGIN])
        self.assertEqual(lines[-1], "0 2 * * * echo after # not ours")
        self.assertNotIn("1 1 * * * stale run", lines)

    def test_old_dotfiles_sync_line_removed(self):
        self.set_crontab("0 1 * * * echo keep\n*/5 * * * * /h/.local/bin/dotfiles-sync.sh # dotfiles-sync\n")
        r = self.jobs("install")
        self.assertNotIn("# dotfiles-sync\n", self.crontab())
        self.assertIn("0 1 * * * echo keep", self.crontab())
        self.assertIn("old dotfiles-sync line", r.stdout)

    def test_malformed_line_refused_naming_it_and_nothing_written(self):
        self.set_crontab("0 1 * * * echo keep\n")
        for bad in ("gamma 1m */5 * * *\n", "gamma 0m */5 * * * * true\n", "gamma 5x */5 * * * * true\n",
                    "alpha 1m */5 * * * * true\n", "gamma 1m host= */5 * * * * true\n"):
            with self.subTest(bad=bad):
                self.write_list(LIST + bad)
                r = self.jobs("install")
                self.assertEqual(r.returncode, 1)
                self.assertIn(":4:", r.stderr)
                self.assertIn(bad.strip(), r.stderr)
                self.assertEqual(self.writes(), 0)

    def test_host_filter(self):
        self.jobs("install", FAKE_HOST="otherbox")
        self.assertNotIn("run beta", self.crontab())
        self.jobs("install", FAKE_HOST="BOXA")
        self.assertIn('0 */6 * * * "$HOME/.local/bin/cron-jobs" run beta', self.crontab())

    def test_linked_systemd_units_retired_tracked_files_left(self):
        unit_dir = self.home / ".config" / "systemd" / "user"
        unit_dir.mkdir(parents=True)
        target = self.home / "repo-alpha.timer"
        target.write_text("[Timer]\n")
        (unit_dir / "alpha.timer").symlink_to(target)
        (unit_dir / "alpha.service").write_text("[Service]\n")
        (self.home / "units-known").write_text("alpha.timer\n")
        r = self.jobs("install")
        log = (self.home / "systemctl.log").read_text()
        self.assertIn("--user disable --now alpha.timer", log)
        self.assertNotIn("disable --now beta.timer", log)
        self.assertFalse((unit_dir / "alpha.timer").exists())
        self.assertTrue((unit_dir / "alpha.service").exists())
        self.assertIn("disabled alpha.timer", r.stdout)

    def test_quiet_prints_nothing(self):
        r = self.jobs("install", "--quiet")
        self.assertEqual((r.returncode, r.stdout), (0, ""))


class Run(Base):
    def state(self, name):
        return self.home / ".local" / "state" / "jobs" / name

    def test_run_logs_and_records_last(self):
        self.write_list("hi 1m * * * * *  echo out; echo err >&2; exit 3\n")
        r = self.jobs("run", "hi")
        self.assertEqual(r.returncode, 3)
        log = self.state("hi.log").read_text()
        self.assertRegex(log.splitlines()[0], r"^=== \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ hi$")
        self.assertIn("out\nerr\n", log)
        last = json.loads(self.state("hi.last").read_text())
        self.assertEqual((last["name"], last["exit"], last["timed_out"]), ("hi", 3, False))
        self.assertTrue(last["started"] <= last["ended"])

    def test_tilde_and_path(self):
        self.write_list("hi 1m * * * * *  echo ~; echo $PATH\n")
        self.jobs("run", "hi")
        log = self.state("hi.log").read_text()
        self.assertIn(f"{self.home}\n{self.home}/.claude/bin:{self.home}/.local/bin:", log)

    def test_timeout_kills_the_process_group(self):
        marker = self.home / "survived"
        self.write_list(f"slow 1s * * * * *  (sleep 3; touch {marker}) & sleep 30\n")
        t0 = time.monotonic()
        r = self.jobs("run", "slow")
        self.assertLess(time.monotonic() - t0, 10)
        self.assertEqual(r.returncode, 124)
        self.assertTrue(json.loads(self.state("slow.last").read_text())["timed_out"])
        time.sleep(3.5)
        self.assertFalse(marker.exists(), "a child of the timed-out job outlived it")

    def test_grandchild_ignoring_term_is_killed(self):
        marker = self.home / "survived"
        self.write_list(f"slow 1s * * * * *  (trap '' TERM; sleep 3; touch {marker}) & sleep 30\n")
        r = self.jobs("run", "slow")
        self.assertEqual(r.returncode, 124)
        time.sleep(3.5)
        self.assertFalse(marker.exists(), "a grandchild that ignores SIGTERM outlived the timeout")

    def test_a_bad_line_stops_only_itself(self):
        self.write_list("bad 0m * * * * * true\nhi 1m * * * * *  echo ran\n")
        r = self.jobs("run", "hi")
        self.assertEqual(r.returncode, 0, r.stderr)
        log = self.state("hi.log").read_text()
        self.assertIn("ran\n", log)
        self.assertIn(":1:", log)
        self.assertEqual(self.jobs("run", "bad").returncode, 2)

    def test_held_lock_skips(self):
        self.write_list("hi 1m * * * * *  touch ran\n")
        self.state("").mkdir(parents=True)
        with open(self.state("hi.lock"), "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
            r = self.jobs("run", "hi")
        self.assertEqual(r.returncode, 0)
        self.assertFalse((self.home / "ran").exists())
        self.assertIn("still running, skipped", self.state("hi.log").read_text())

    def test_log_capped_keeping_the_tail(self):
        self.write_list("big 1m * * * * *  echo newest\n")
        self.state("").mkdir(parents=True)
        self.state("big.log").write_text("old line\n" * 150_000)
        self.jobs("run", "big")
        log = self.state("big.log").read_text()
        self.assertLessEqual(len(log), 1_000_000)
        self.assertIn("newest", log)

    def test_unknown_job(self):
        self.assertEqual(self.jobs("run", "nope").returncode, 2)


class RealList(Base):
    LIST = SCRIPT.parent.parent.parent / ".config" / "jobs"

    def test_the_shipped_list_parses_strictly(self):
        self.write_list(self.LIST.read_text())
        self.assertEqual(self.jobs("install").returncode, 0)

    def test_state_push_without_a_state_repo_is_not_a_failure(self):
        self.write_list(self.LIST.read_text())
        stub = self.home / ".claude" / "bin" / "state-push"
        stub.parent.mkdir(parents=True)
        for code, want in ((2, 0), (1, 1), (0, 0)):
            with self.subTest(code=code):
                stub.write_text(f"#!/bin/sh\nexit {code}\n")
                stub.chmod(0o755)
                self.assertEqual(self.jobs("run", "state-push").returncode, want)


class Status(Base):
    def test_status_flags_missing_block_failures_and_host_skips(self):
        r = self.jobs("status")
        self.assertEqual(r.returncode, 1)
        self.assertIn("missing", r.stdout)
        self.assertIn("skipped (host)", r.stdout)
        self.jobs("install")
        self.assertEqual(self.jobs("status").returncode, 0)
        self.write_list(LIST.replace("echo alpha", "exit 1"))
        self.jobs("run", "alpha")
        self.assertEqual(self.jobs("status").returncode, 1)

    def test_status_flags_a_bad_line(self):
        self.jobs("install")
        self.write_list(LIST + "gamma 1x */5 * * * * true\n")
        r = self.jobs("status")
        self.assertEqual(r.returncode, 1)
        self.assertIn("gamma 1x", r.stdout)
        self.assertIn("alpha", r.stdout)

    def test_status_flags_stale_block(self):
        self.jobs("install")
        self.write_list(LIST.replace("*/5", "*/10"))
        r = self.jobs("status")
        self.assertEqual(r.returncode, 1)
        self.assertIn("stale", r.stdout)


if __name__ == "__main__":
    unittest.main()
