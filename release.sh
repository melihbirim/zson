#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

current_branch="$(git branch --show-current)"
if [[ "$current_branch" != "main" ]]; then
  echo "release.sh: must run from main, current branch is '$current_branch'" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "release.sh: working tree is not clean" >&2
  git status --short
  exit 1
fi

git fetch --tags origin

latest_tag="$(git tag --sort=-v:refname | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1 || true)"
if [[ -z "$latest_tag" ]]; then
  next_tag="v0.1.0"
else
  version="${latest_tag#v}"
  IFS=. read -r major minor patch <<< "$version"
  next_tag="v${major}.${minor}.$((patch + 1))"
fi

tag="${1:-$next_tag}"
if ! [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release.sh: tag must look like v1.2.3, got '$tag'" >&2
  exit 1
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "release.sh: tag '$tag' already exists" >&2
  exit 1
fi

git diff --quiet origin/main..HEAD || {
  echo "release.sh: local main differs from origin/main; push or pull first" >&2
  exit 1
}

zig fmt --check src/ build.zig
zig build test
zig build -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
zig build -Dtarget=aarch64-macos -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseFast

git tag -a "$tag" -m "$tag"
git push origin "$tag"

echo "release.sh: released $tag"
