#!/usr/bin/env bash
# Fails when a Bicep or .bicepparam file is not in `az bicep format` style,
# and prints the diff so the fix is obvious. `make fmt` rewrites the files.
set -euo pipefail

cd "$(dirname "$0")/.."
status=0
while IFS= read -r file; do
  formatted="$(az bicep format --file "$file" --stdout 2>/dev/null)"
  if ! diff -u --label "$file" --label "$file (formatted)" "$file" <(printf '%s\n' "$formatted"); then
    status=1
  fi
done < <(find infra modules \( -name '*.bicep' -o -name '*.bicepparam' \) | sort)

[[ $status -eq 0 ]] && echo "format ok"
exit "$status"
