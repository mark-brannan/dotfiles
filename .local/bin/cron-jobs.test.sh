#!/bin/sh
# CI runs .local/bin/*.test.sh; the tests themselves are Python.
exec python3 "$(dirname "$0")/cron-jobs.test.py"
