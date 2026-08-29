#!/usr/bin/env bash
# install.sh — one-time MusterAI setup for this machine.
#
#   1. Checks required dependencies are installed (claude, herdr, just, yq, jq, git).
#   2. Symlinks agents/*.md into ~/.claude/agents/ so every role is discoverable
#      by `claude --agent <role>` from any project on this machine.
#   3. Adds a `muster` shell function to your shell rc file, so `muster team ...`
#      works from inside any project directory, not just this repo.
#
# Safe to re-run: symlinks are recreated, and the shell rc snippet is only
# added once (guarded by a marker comment).
set -euo pipefail

MUSTER_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "== checking dependencies =="
MISSING=()
for cmd in claude herdr just yq jq git; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf '  ok   %s (%s)\n' "$cmd" "$(command -v "$cmd")"
  else
    printf '  MISSING  %s\n' "$cmd"
    MISSING+=("$cmd")
  fi
done
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo
  echo "Missing: ${MISSING[*]}"
  echo "  claude : https://claude.com/claude-code (or your work install method)"
  echo "  herdr  : curl -fsSL https://herdr.dev/install.sh | sh"
  echo "  just   : brew install just   (or: apt install just / cargo install just)"
  echo "  yq     : brew install yq     (or: apt install yq)"
  echo "  jq     : brew install jq     (or: apt install jq)"
  echo
  echo "Install the missing tools above, then re-run install.sh."
  exit 1
fi

echo
echo "== linking agent roles into ~/.claude/agents/ =="
mkdir -p "$HOME/.claude/agents"
for f in "$MUSTER_HOME"/agents/*.md; do
  name="$(basename "$f")"
  ln -sf "$f" "$HOME/.claude/agents/$name"
  echo "  linked $name"
done

echo
echo "== wiring up the global 'muster' command =="
MARKER="# >>> musterai >>>"
END_MARKER="# <<< musterai <<<"
SNIPPET="$MARKER
# Run MusterAI's justfile from any directory, against that directory's project.
muster() {
  just --justfile \"$MUSTER_HOME/justfile\" --working-directory . \"\$@\"
}
$END_MARKER"

RC=""
if [[ -n "${ZSH_VERSION:-}" || "$SHELL" == */zsh ]]; then
  RC="$HOME/.zshrc"
elif [[ -n "${BASH_VERSION:-}" || "$SHELL" == */bash ]]; then
  RC="$HOME/.bashrc"
else
  RC="$HOME/.profile"
fi

if [[ -f "$RC" ]] && grep -qF "$MARKER" "$RC"; then
  # Replace the existing block in place (handles a moved/renamed repo path).
  tmp="$(mktemp)"
  awk -v marker="$MARKER" -v endmarker="$END_MARKER" '
    $0 == marker {skip=1}
    !skip {print}
    $0 == endmarker {skip=0}
  ' "$RC" >"$tmp"
  printf '%s\n' "$SNIPPET" >>"$tmp"
  mv "$tmp" "$RC"
  echo "  updated existing muster block in $RC"
else
  printf '\n%s\n' "$SNIPPET" >>"$RC"
  echo "  added muster() to $RC"
fi

echo
echo "Done. Open a new shell (or 'source $RC'), then from any project repo:"
echo "  muster roles"
echo "  muster presets"
echo "  muster team planner-builder-tester"
echo "  muster spawn data-engineer"
echo "  muster stop-team <team-name>"
