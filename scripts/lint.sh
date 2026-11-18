#!/usr/bin/env bash
# Lints every Bicep file. `az bicep lint` exits 0 on warnings, so any output
# at all is treated as a failure.
set -euo pipefail

cd "$(dirname "$0")/.."
status=0
while IFS= read -r file; do
  output="$(az bicep lint --file "$file" 2>&1)"
  if [[ -n "$output" ]]; then
    echo "$output"
    status=1
  fi
done < <(find infra modules -name '*.bicep' | sort)

[[ $status -eq 0 ]] && echo "lint ok"
exit "$status"
