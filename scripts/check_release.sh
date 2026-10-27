#!/usr/bin/env bash
# Checks that a release tag names the version in mix.exs, so a tag can never publish another version.
# Usage: scripts/check_release.sh v0.2.0
set -euo pipefail

tag="${1:-}"

if [[ ! "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "the tag must look like v1.2.3 or v1.2.3-rc.1, got '${tag}'" >&2
  exit 1
fi

version="$(sed -nE 's/^ +version: "([^"]+)",?$/\1/p' mix.exs | head -n 1)"

if [[ -z "$version" ]]; then
  echo "could not read the version from mix.exs" >&2
  exit 1
fi

if [[ "$tag" != "v${version}" ]]; then
  echo "the tag ${tag} does not match the version ${version} in mix.exs" >&2
  exit 1
fi

echo "tag ${tag} matches version ${version}"
