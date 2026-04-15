#!/usr/bin/env bash
set -euo pipefail

response="${!#}"

python3 - "$response" <<'PY'
import json
import sys

response = sys.argv[1]
chunk_size = 12

for index in range(0, len(response), chunk_size):
    chunk = response[index:index + chunk_size]
    print("data: " + json.dumps({"choices": [{"delta": {"content": chunk}}]}))
    print()

print("data: [DONE]")
print()
PY
