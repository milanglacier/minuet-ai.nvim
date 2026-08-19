#!/usr/bin/env bash
# Stands in for curl: writes the arguments it received to the file given as the
# first argument, and a copy of the request body to "<file>.body".
set -euo pipefail

output="$1"
shift

printf '%s\n' "$@" >"$output"

previous=""
for arg in "$@"; do
    if [[ $previous == "-d" && $arg == @* ]]; then
        cp "${arg#@}" "$output.body"
    fi
    previous="$arg"
done
