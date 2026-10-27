#!/usr/bin/env bash
# Builds the bilingual docs site into site/, one Zensical build per language.
# Building both into a shared site_dir would make each build wipe the other.
#
# Usage: bash scripts/build_docs.sh
set -euo pipefail
cd "$(dirname "$0")/.."

ZENSICAL_VERSION="${ZENSICAL_VERSION:-0.0.72}"

rm -rf .docs-build site
uvx --from "zensical==${ZENSICAL_VERSION}" zensical build --strict -f zensical.en.yml
uvx --from "zensical==${ZENSICAL_VERSION}" zensical build --strict -f zensical.pt.yml

mkdir -p site
cp -R .docs-build/en/. site/
cp -R .docs-build/pt site/pt
