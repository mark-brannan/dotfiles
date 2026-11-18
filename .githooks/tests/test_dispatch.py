#!/usr/bin/env python3
"""Tests for .githooks/dispatch, the global core.hooksPath entry point.

Each test drives real git in a throwaway repo whose core.hooksPath is a
copy of .githooks with the checks swapped for stubs that log their calls,
so what is asserted is which checks ran, at which hook, with what input.
One test at the end runs a real check through the real directory.

Run: python3 .githooks/tests/test_dispatch.py
"""
import os
import shutil
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
GITHOOKS = os.path.dirname(HERE)

STUBS = {
    "gitleaks_precommit.sh": "gitleaks",
    "lint_repo_hygiene.py": "repo-hygiene",
    "check_encoding_health.py": "encoding-health",
    "check_vuln_shape.py": "vuln-shape",
    "prepush_secret_scan.sh": "prepush-secret-scan",
}

# A stub logs its name, its args and its stdin, and fails if $FAIL names it.
STUB_PY = """import os, sys
data = sys.stdin.read()
with open(os.environ["LOG"], "a") as f:
    f.write("%s|%s|%s\\n" % ({name!r}, " ".join(sys.argv[1:]), data.replace("\\n", ";")))
sys.exit(1 if os.environ.get("FAIL") == {name!r} else 0)
"""
STUB_SH = """data=$(cat | tr '\\n' ';')
printf '%s|%s|%s\\n' {name} "$*" "$data" >>"$LOG"
[ "${{FAIL:-}}" != {name} ]
"""


def hook_names():
    return sorted(n for n in os.listdir(GITHOOKS)
                  if os.path.islink(os.path.join(GITHOOKS, n))
                  and os.readlink(os.path.join(GITHOOKS, n)) == "dispatch")


class DispatchTest(unittest.TestCase):

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)
        self.hooks = os.path.join(self.tmp, "githooks")
        os.makedirs(os.path.join(self.hooks, "checks"))
        shutil.copy2(os.path.join(GITHOOKS, "dispatch"), self.hooks)
        for name in hook_names():
            os.symlink("dispatch", os.path.join(self.hooks, name))
        for script, name in STUBS.items():
            body = (STUB_PY if script.endswith(".py") else STUB_SH).format(name=name)
            with open(os.path.join(self.hooks, "checks", script), "w") as f:
                f.write(body)

        self.log = os.path.join(self.tmp, "log")
        gitconfig = os.path.join(self.tmp, "gitconfig")
        with open(gitconfig, "w") as f:
            f.write("[core]\n\thooksPath = %s\n[user]\n\tname = t\n\temail = t@example.invalid\n"
                    "[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n" % self.hooks)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "PRE_COMMIT")) and k not in ("CI", "GITHUB_ACTIONS")}
        xdg = os.path.join(self.tmp, "xdg")
        os.makedirs(os.path.join(xdg, "githooks"))
        self.trusted = os.path.join(xdg, "githooks", "trusted-repos")
        self.env.update(GIT_CONFIG_GLOBAL=gitconfig, GIT_CONFIG_NOSYSTEM="1", LOG=self.log,
                        XDG_CONFIG_HOME=xdg)

        self.repo = os.path.join(self.tmp, "repo")
        self.git("init", "-q", self.repo, cwd=self.tmp)
        self.remote = os.path.join(self.tmp, "remote.git")
        self.git("init", "-q", "--bare", self.remote, cwd=self.tmp)
        self.git("remote", "add", "origin", self.remote)
        self.trust(self.remote[:-len(".git")])

    def trust(self, *origins):
        with open(self.trusted, "w") as f:
            f.write("# trusted\n" + "".join(o + "\n" for o in origins))

    def git(self, *args, cwd=None, check=True, **env):
        r = subprocess.run(["git", *args], cwd=cwd or self.repo, text=True,
                           capture_output=True, env={**self.env, **env}, timeout=30)
        if check and r.returncode:
            self.fail("git %s failed: %s%s" % (" ".join(args), r.stdout, r.stderr))
        return r

    def commit(self, check=True, **env):
        with open(os.path.join(self.repo, "f"), "a") as f:
            f.write("x\n")
        self.git("add", "f")
        return self.git("commit", "-q", "-m", "m", check=check, **env)

    def opt_in(self, text):
        with open(os.path.join(self.repo, ".githooks-checks"), "w") as f:
            f.write(text)

    def own_hook(self, name, body, gitdir=None):
        path = os.path.join(gitdir or os.path.join(self.repo, ".git"), "hooks", name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)

    def ran(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return [line.rstrip("\n").split("|") for line in f]

    # --- the repo's own hooks survive the global hooksPath --------------------

    def test_own_hook_runs_with_no_opt_in_file(self):
        self.own_hook("pre-commit", 'echo own >>"$LOG"\n')
        self.commit()
        self.assertEqual(self.ran(), [["own"]])

    def test_own_hook_failure_blocks_and_checks_do_not_run(self):
        self.opt_in("gitleaks\n")
        self.own_hook("pre-commit", "exit 3\n")
        self.assertNotEqual(self.commit(check=False).returncode, 0)
        self.assertEqual(self.ran(), [])

    def test_other_hooks_pass_through_with_args(self):
        self.own_hook("commit-msg", 'printf "msg|%s\\n" "$(cat "$1")" >>"$LOG"\n')
        self.commit()
        self.assertEqual(self.ran(), [["msg", "m"]])

    def test_other_hook_failure_still_blocks(self):
        self.own_hook("commit-msg", "exit 1\n")
        self.assertNotEqual(self.commit(check=False).returncode, 0)

    def test_non_executable_own_hook_is_ignored_like_git_does(self):
        self.own_hook("pre-commit", "exit 1\n")
        os.chmod(os.path.join(self.repo, ".git", "hooks", "pre-commit"), 0o644)
        self.commit()

    def test_own_hook_linked_to_dispatch_does_not_recurse(self):
        os.symlink(os.path.join(self.hooks, "pre-commit"),
                   os.path.join(self.repo, ".git", "hooks", "pre-commit"))
        self.opt_in("gitleaks\n")
        self.commit()
        self.assertEqual([r[0] for r in self.ran()], ["gitleaks"])

    def test_linked_worktree_runs_the_common_hook_and_its_own_opt_in(self):
        self.own_hook("pre-commit", 'echo own >>"$LOG"\n')
        self.commit()
        wt = os.path.join(self.tmp, "wt")
        self.git("worktree", "add", "-q", "-b", "side", wt)
        with open(os.path.join(wt, ".githooks-checks"), "w") as f:
            f.write("encoding-health\n")
        with open(os.path.join(wt, "g"), "w") as f:
            f.write("y\n")
        self.git("add", "g", cwd=wt)
        self.git("commit", "-q", "-m", "w", cwd=wt)
        self.assertEqual([r[0] for r in self.ran()], ["own", "own", "encoding-health"])

    # --- opt-in --------------------------------------------------------------

    def test_no_opt_in_file_runs_no_checks(self):
        self.commit()
        self.git("push", "-q", "origin", "main")
        self.assertEqual(self.ran(), [])

    def test_pre_commit_runs_only_the_listed_pre_commit_checks(self):
        self.opt_in("# shared checks\ngitleaks\n\n  encoding-health  # staged files\nprepush-secret-scan")
        self.commit()
        self.assertEqual(self.ran(), [["gitleaks", "", ""], ["encoding-health", "--staged", ""]])

    def test_failing_check_blocks_but_the_rest_still_run(self):
        self.opt_in("gitleaks\nrepo-hygiene\n")
        r = self.commit(check=False, FAIL="gitleaks")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("gitleaks", r.stderr)
        self.assertEqual([x[0] for x in self.ran()], ["gitleaks", "repo-hygiene"])

    def test_unknown_check_name_blocks(self):
        self.opt_in("gitleak\n")
        r = self.commit(check=False)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("gitleak", r.stderr)

    # --- trust: only an allowlisted origin has its file honoured --------------

    def test_untrusted_repo_with_hostile_checks_file_runs_nothing(self):
        self.trust("github.com/someone/else")
        self.opt_in("gitleaks\nrepo-hygiene\nencoding-health\nvuln-shape\nprepush-secret-scan\n")
        os.makedirs(os.path.join(self.repo, "docker", "gitleaks"))
        with open(os.path.join(self.repo, "docker", "gitleaks", "Dockerfile"), "w") as f:
            f.write("FROM example.invalid/hostile:latest\n")
        self.own_hook("pre-commit", 'echo own >>"$LOG"\n')
        r = self.commit()
        self.git("push", "-q", "origin", "main")
        self.assertEqual(self.ran(), [["own"]])
        self.assertIn("not in", r.stderr)

    def test_repo_with_no_origin_runs_nothing(self):
        self.git("remote", "remove", "origin")
        self.opt_in("gitleaks\n")
        self.commit()
        self.assertEqual(self.ran(), [])

    def test_no_trust_list_runs_nothing(self):
        os.remove(self.trusted)
        self.opt_in("gitleaks\n")
        self.commit()
        self.assertEqual(self.ran(), [])

    def test_trusted_origin_matches_across_url_forms(self):
        self.trust("github.com/mark-brannan/symphony")
        self.opt_in("gitleaks\n")
        for url in ("git@GitHub.com:mark-brannan/symphony.git",
                    "https://github.com/mark-brannan/symphony",
                    "ssh://git@github.com/mark-brannan/symphony.git/"):
            self.git("remote", "set-url", "origin", url)
            self.commit()
        self.git("remote", "set-url", "origin", "https://github.com/mark-brannan/symphony-fork")
        self.commit()
        self.assertEqual([r[0] for r in self.ran()], ["gitleaks"] * 3)

    def test_pre_push_feeds_the_same_refs_to_own_hook_and_check(self):
        self.opt_in("prepush-secret-scan\ngitleaks\n")
        self.own_hook("pre-push", 'printf "own|%s|%s\\n" "$1" "$(cat | tr "\\n" ";")" >>"$LOG"\n')
        self.commit()
        os.remove(self.log)
        self.git("push", "-q", "origin", "main")
        head = self.git("rev-parse", "HEAD").stdout.strip()
        rows = self.ran()
        self.assertEqual([r[0] for r in rows], ["own", "prepush-secret-scan"])
        self.assertEqual(rows[0][1], "origin")
        for r in rows:
            self.assertIn(head, r[-1])
        self.assertEqual(rows[0][-1], rows[1][-1])

    def test_failing_push_check_blocks_the_push(self):
        self.opt_in("prepush-secret-scan\n")
        self.commit()
        r = self.git("push", "-q", "origin", "main", check=False, FAIL="prepush-secret-scan")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.git("ls-remote", "origin").stdout.strip(), "")


class RealChecksTest(unittest.TestCase):
    """The real .githooks directory and real checks, end to end."""

    def test_encoding_health_blocks_a_non_utf8_file(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        gitconfig = os.path.join(tmp, "gitconfig")
        with open(gitconfig, "w") as f:
            f.write("[core]\n\thooksPath = %s\n[user]\n\tname = t\n\temail = t@example.invalid\n"
                    "[commit]\n\tgpgsign = false\n" % GITHOOKS)
        os.makedirs(os.path.join(tmp, "xdg", "githooks"))
        with open(os.path.join(tmp, "xdg", "githooks", "trusted-repos"), "w") as f:
            f.write("example.invalid/me/repo\n")
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        env.update(GIT_CONFIG_GLOBAL=gitconfig, GIT_CONFIG_NOSYSTEM="1",
                   XDG_CONFIG_HOME=os.path.join(tmp, "xdg"))
        repo = os.path.join(tmp, "repo")

        def git(*a):
            return subprocess.run(["git", *a], cwd=repo, env=env, capture_output=True, text=True)

        os.makedirs(repo)
        git("init", "-q")
        git("remote", "add", "origin", "https://example.invalid/me/repo.git")
        with open(os.path.join(repo, ".githooks-checks"), "w") as f:
            f.write("encoding-health\n")
        with open(os.path.join(repo, "bad.md"), "wb") as f:
            f.write(b"caf\xe9\n")
        git("add", "bad.md")
        self.assertNotEqual(git("commit", "-q", "-m", "bad").returncode, 0)

        with open(os.path.join(repo, "bad.md"), "wb") as f:
            f.write("café\n".encode())
        git("add", "bad.md")
        r = git("commit", "-q", "-m", "good")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


    def test_gitleaks_runs_the_pinned_image_never_the_repos(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp)
        bin_dir = os.path.join(tmp, "bin")
        os.makedirs(bin_dir)
        log = os.path.join(tmp, "docker.log")
        with open(os.path.join(bin_dir, "docker"), "w") as f:
            f.write('#!/bin/sh\n[ "$1" = info ] && exit 0\nprintf "%%s\\n" "$@" >"%s"\n' % log)
        os.chmod(os.path.join(bin_dir, "docker"), 0o755)
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k != "GITLEAKS_IMAGE"}
        env.update(PATH=bin_dir + os.pathsep + env["PATH"], GIT_CONFIG_GLOBAL="/dev/null",
                   GIT_CONFIG_NOSYSTEM="1")
        repo = os.path.join(tmp, "repo")
        os.makedirs(os.path.join(repo, "docker", "gitleaks"))
        subprocess.run(["git", "init", "-q"], cwd=repo, env=env, check=True)
        with open(os.path.join(repo, "docker", "gitleaks", "Dockerfile"), "w") as f:
            f.write("FROM example.invalid/hostile:latest\n")
        subprocess.run(["bash", os.path.join(GITHOOKS, "checks", "gitleaks_precommit.sh")],
                       cwd=repo, env=env, check=True, capture_output=True)
        with open(os.path.join(GITHOOKS, "docker", "gitleaks", "Dockerfile")) as f:
            pin = next(l.split()[1] for l in f if l.startswith("FROM "))
        with open(log) as f:
            args = f.read().split("\n")
        self.assertIn("@sha256:", pin)
        self.assertEqual(args[args.index("--") + 1], pin)
        self.assertNotIn("example.invalid/hostile:latest", args)


if __name__ == "__main__":
    unittest.main()
