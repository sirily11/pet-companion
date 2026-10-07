#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TASK_PACKAGE="$TASK_ROOT/build/native-mlx-swift-lm"
TASK_REVISION=ecd8e88f8cbcab1c5e4ecad4958a8de6ab96d976
if [[ ! -f "$TASK_PACKAGE/Package.swift" ]]; then
  mkdir -p "$TASK_ROOT/build"
  if [[ -d "$TASK_ROOT/build/SourcePackages/checkouts/mlx-swift-lm/.git" ]]; then
    git clone --quiet --local "$TASK_ROOT/build/SourcePackages/checkouts/mlx-swift-lm" "$TASK_PACKAGE"
  else
    git clone --quiet --filter=blob:none --no-checkout https://github.com/ml-explore/mlx-swift-lm "$TASK_PACKAGE"
  fi
  git -C "$TASK_PACKAGE" checkout --quiet --detach "$TASK_REVISION"
fi
[[ "$(git -C "$TASK_PACKAGE" rev-parse HEAD)" == "$TASK_REVISION" ]] || { echo 'Unexpected native MLX dependency revision' >&2; exit 1; }
python3 "$TASK_ROOT/scripts/dependencies/patch-openjev-norm.py" "$TASK_PACKAGE"
