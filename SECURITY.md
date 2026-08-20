# Security Policy

## Reporting a vulnerability

Please report security issues privately using GitHub's [private vulnerability
reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability):
open the **Security** tab on this repo → **Report a vulnerability**. That
opens a private advisory only the repo owner can see — please don't file a
public issue for anything sensitive.

Include what you found, how to reproduce it, and its impact if that's clear.
Expect an initial response within a few days.

## Scope

This is a personal dotfiles repository. Relevant reports include:

- Secrets or key material committed unencrypted (anything that should be
  sops/age-encrypted under `.sops.yaml` but isn't)
- A bootstrap or hook script (`.config/yadm/bootstrap`, `.claude/hooks/*`)
  that executes untrusted input, fetches over an insecure channel, or
  otherwise creates a path to code execution beyond what's expected of a
  dotfiles install
- Anything else that could compromise a machine that clones and bootstraps
  this repo as documented in the README

Out of scope: issues in third-party tools this repo merely configures
(yadm, sops, age, Claude Code, etc.) — report those upstream instead.

## Supported versions

This repo tracks a single branch (`main`) with no version releases. Fixes
land on `main`; there's nothing older to backport to.
