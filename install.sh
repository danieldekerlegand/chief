#!/usr/bin/env sh
# install.sh — install/update the chief engine + a `chief` shim. No root/brew needed.
#   curl -fsSL <raw-url>/install.sh | sh
# Env: CHIEF_REPO, CHIEF_VERSION (branch/tag), CHIEF_PREFIX (~/.chief), CHIEF_BINDIR (~/.local/bin)
set -eu
REPO_URL="${CHIEF_REPO:-https://github.com/danieldekerlegand/chief.git}"
VERSION="${CHIEF_VERSION:-main}"
PREFIX="${CHIEF_PREFIX:-$HOME/.chief}"
BINDIR="${CHIEF_BINDIR:-$HOME/.local/bin}"
SRC="$PREFIX/src"

for arg in "$@"; do
  case "$arg" in
    -h|--help)   echo "usage: install.sh  (env: CHIEF_REPO CHIEF_VERSION CHIEF_PREFIX CHIEF_BINDIR)"; exit 0 ;;
    *)           echo "install.sh: unknown argument '$arg'" >&2; exit 2 ;;
  esac
done

mkdir -p "$PREFIX" "$BINDIR"
if [ -d "$SRC/.git" ]; then
  echo "→ updating $SRC ($VERSION)"
  git -C "$SRC" fetch --quiet origin && git -C "$SRC" checkout --quiet "$VERSION" 2>/dev/null || true
  git -C "$SRC" pull --quiet --ff-only 2>/dev/null || true
else
  echo "→ cloning $REPO_URL ($VERSION) → $SRC"
  git clone --quiet --branch "$VERSION" "$REPO_URL" "$SRC" 2>/dev/null || git clone --quiet "$REPO_URL" "$SRC"
fi
chmod +x "$SRC/bin/chief" "$SRC/engine/"*.sh 2>/dev/null || true
ln -sf "$SRC/bin/chief" "$BINDIR/chief"
echo "✓ installed chief $(cat "$SRC/VERSION" 2>/dev/null || echo '?') → $BINDIR/chief"

case ":$PATH:" in *":$BINDIR:"*) : ;; *) echo "  add to PATH:  export PATH=\"$BINDIR:\$PATH\"" ;; esac
echo "  then, in a repo:  chief init"
