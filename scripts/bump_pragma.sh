#!/usr/bin/env bash
set -euo pipefail

TARGET="^0.8.24"
ROOT="${1:-src}"

# Find all .sol files under ROOT
mapfile -t FILES < <(find "$ROOT" -type f -name '*.sol' -print)

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "No .sol files found under: $ROOT"
  exit 0
fi

for f in "${FILES[@]}"; do
  # If file already has a pragma solidity line, replace it
  if grep -Eq '^[[:space:]]*pragma[[:space:]]+solidity[[:space:]]+' "$f"; then
    perl -0777 -i -pe "s/^[[:space:]]*pragma[[:space:]]+solidity[[:space:]]+[^;]+;/pragma solidity ${TARGET};/m" "$f"
    echo "updated pragma: $f"
    continue
  fi

  # Otherwise insert pragma.
  # Prefer inserting after SPDX line if present, else at top.
  if grep -Eq '^[[:space:]]*//[[:space:]]*SPDX-License-Identifier:' "$f"; then
    perl -0777 -i -pe "s/^([[:space:]]*\\/\\/[[:space:]]*SPDX-License-Identifier:[^\n]*\n)/\$1\npragma solidity ${TARGET};\n/m" "$f"
  else
    perl -0777 -i -pe "s/^/pragma solidity ${TARGET};\n\n/" "$f"
  fi

  echo "inserted pragma: $f"
done

echo "Done. Target pragma: pragma solidity ${TARGET};"
