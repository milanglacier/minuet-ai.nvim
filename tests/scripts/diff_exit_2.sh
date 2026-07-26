#!/bin/sh
# Mimics a diff invocation failing outright (exit status >= 2).
echo 'diff_exit_2.sh: simulated diff failure' >&2
exit 2
