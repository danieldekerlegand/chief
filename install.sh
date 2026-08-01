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
  # Track the remote EXACTLY. The install prefix holds no local commits worth keeping,
  # and a fast-forward pull cannot cross a force-push or a re-rooted (unrelated) history
  # — it fails silently and freezes the install on a stale VERSION. Hard-reset instead.
  git -C "$SRC" fetch --quiet --tags --force origin || true
  if git -C "$SRC" rev-parse --verify --quiet "origin/$VERSION" >/dev/null 2>&1; then
    git -C "$SRC" reset --hard --quiet "origin/$VERSION"
  else
    git -C "$SRC" reset --hard --quiet "$VERSION"   # a tag or a sha, not a branch
  fi
else
  echo "→ cloning $REPO_URL ($VERSION) → $SRC"
  git clone --quiet --branch "$VERSION" "$REPO_URL" "$SRC" 2>/dev/null || git clone --quiet "$REPO_URL" "$SRC"
fi
chmod +x "$SRC/bin/chief" "$SRC/engine/"*.sh 2>/dev/null || true
ln -sf "$SRC/bin/chief" "$BINDIR/chief"
echo "✓ installed chief $(cat "$SRC/VERSION" 2>/dev/null || echo '?') → $BINDIR/chief"

case ":$PATH:" in *":$BINDIR:"*) : ;; *) echo "  add to PATH:  export PATH=\"$BINDIR:\$PATH\"" ;; esac
echo "  then, in a repo:  chief init"
