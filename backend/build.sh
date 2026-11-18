#!/usr/bin/env bash
# Builds every function into backend/build/<function>/:
# its own code + its libraries + a copy of shared/. Terraform zips that folder.
set -euo pipefail
cd "$(dirname "$0")"

OUT="build"
rm -rf "$OUT"
mkdir -p "$OUT"

for dir in init_db get_tutorials create_tutorial rate_tutorial; do
  [ -d "$dir" ] || continue
  echo "Building $dir"
  mkdir -p "$OUT/$dir"

  cp "$dir"/*.py "$OUT/$dir/"

  # requirements.txt may be empty (placeholders): install only if it has content
  if [ -s "$dir/requirements.txt" ]; then
    python3 -m pip install --quiet --upgrade --no-compile \
      -r "$dir/requirements.txt" --target "$OUT/$dir"
  fi

  if [ -d shared ]; then
    cp -r shared "$OUT/$dir/shared"
  fi
done

# No bytecode caches in the zips
find "$OUT" -name "__pycache__" -type d -prune -exec rm -rf {} +
echo "Done: $(pwd)/$OUT"
