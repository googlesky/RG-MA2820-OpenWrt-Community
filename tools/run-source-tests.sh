#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail

project_dir=$(cd "$(dirname "$0")/.." && pwd)

find "$project_dir/tools" -maxdepth 1 -type f -name '*.sh' -print0 |
	while IFS= read -r -d '' script; do bash -n "$script"; done
find "$project_dir/tests" -maxdepth 1 -type f -name '*.sh' -print0 |
	while IFS= read -r -d '' script; do bash -n "$script"; done

python3 -m py_compile "$project_dir"/tools/*.py

for test in "$project_dir"/tests/test-*.sh; do
	"$test"
done

echo 'all source tests: PASS'
