#!/usr/bin/env bash
# lib.sh — shared helpers for MusterAI's bin/ scripts.
# Sourced by spawn-agent, team, and stop-team. Expects MUSTER_HOME to already be set.

muster_log() { echo "muster: $*" >&2; }

muster_die() {
  echo "muster: $*" >&2
  exit 1
}

# muster_agent_name <team> <suffix>
# Builds a herdr-safe agent name: "<team>-<suffix>" (suffix is a role, or
# role-N for a repeated role). herdr caps agent names at 32 characters —
# when the natural name is too long, this truncates the team portion and
# appends a short checksum of the *full* original name, so two long team
# names that happen to share a prefix still can't collide after truncation.
muster_agent_name() {
  local team="$1" suffix="$2"
  local full="${team}-${suffix}"
  if [[ ${#full} -le 32 ]]; then
    echo "$full"
    return
  fi

  # h + 3 digits: short enough that even our longest role name (with a -N
  # repeat suffix) still fits alongside it; still enough entropy that two
  # concurrent teams colliding on it is not a realistic concern at this
  # tool's scale.
  local hash budget
  hash=$(printf 'h%03d' $(( $(printf '%s' "$full" | cksum | cut -d' ' -f1) % 1000 )))

  # Prefer keeping some of the team name: <team_trunc>-<hash>-<suffix>.
  budget=$((32 - ${#suffix} - ${#hash} - 2))
  if [[ $budget -ge 1 ]]; then
    echo "${team:0:$budget}-${hash}-${suffix}"
    return
  fi

  # No room for any team portion — <hash>-<suffix>.
  budget=$((32 - ${#suffix} - ${#hash} - 1))
  if [[ $budget -ge 0 ]]; then
    echo "${hash}-${suffix}"
    return
  fi

  # Suffix itself is too long even alone with the hash (an unusually long
  # role name combined with a double-digit repeat count) — truncate it too.
  budget=$((32 - ${#hash} - 1))
  echo "${hash}-${suffix:0:$budget}"
}

muster_require_role() {
  local role="$1"
  [[ -f "$MUSTER_HOME/agents/${role}.md" ]] || {
    echo "muster: unknown role '$role' (no agents/${role}.md). Available roles:" >&2
    ls "$MUSTER_HOME/agents" | sed 's/\.md$//' | sed 's/^/  - /' >&2
    exit 1
  }
}

muster_require_git_repo() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
    muster_die "'$1' is not a git repository — run this from inside your target project."
}

# muster_role_field <role> <field> [default]
# Extracts a field from an agent file's YAML frontmatter (the block between the
# first two `---` lines). Claude Code itself only reads name/description/model/
# color/tools from this block; the extra fields below (worktree, permission-mode,
# allowed-tools) are MusterAI-only metadata it silently ignores.
muster_role_field() {
  local role="$1" field="$2" default="${3:-}"
  local file="$MUSTER_HOME/agents/${role}.md"
  local fm val
  fm="$(awk '/^---$/{n++; next} n==1{print} n==2{exit}' "$file")"
  val="$(yq -r ".\"${field}\" // \"\"" <<<"$fm" 2>/dev/null)"
  if [[ -z "$val" || "$val" == "null" ]]; then
    val="$default"
  fi
  echo "$val"
}

muster_state_dir() {
  local dir="${MUSTER_STATE_DIR:-$HOME/.muster/teams}"
  mkdir -p "$dir"
  echo "$dir"
}

muster_state_file() {
  echo "$(muster_state_dir)/$1.json"
}

# Where an agent's isolated worktree lives: outside the project and outside
# the MusterAI repo, keyed by project name so different projects don't collide.
muster_worktree_path() {
  local project_dir="$1" name="$2"
  echo "$HOME/.muster/worktrees/$(basename "$project_dir")/${name}"
}

# muster_create_worktree <project_dir> <path> <branch>
# Creates a git worktree at <path> on a new branch <branch> off HEAD.
# Branch names are deterministic (muster/<instance-name>), so respawning the
# same instance name in the same project collides with a branch left behind
# by an earlier team `stop-team` never tore down (a manually-closed
# workspace, a crash, or simply an older MusterAI that didn't clean up
# branches yet). If the branch exists, isn't checked out anywhere, and is
# fully merged into HEAD, it's safe leftover — replaced automatically. If it
# has real unmerged commits, refuse rather than silently discard someone's
# actual work.
muster_create_worktree() {
  local project_dir="$1" path="$2" branch="$3"

  [[ -e "$path" ]] && muster_die "worktree path already exists: $path (pick a different instance name, or clean it up first)"

  if git -C "$project_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    if git -C "$project_dir" worktree list --porcelain | grep -qx "branch refs/heads/$branch"; then
      muster_die "branch '$branch' is already checked out in another worktree — run 'git -C \"$project_dir\" worktree list' to find it, or pick a different instance name."
    fi
    if git -C "$project_dir" merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
      muster_log "branch '$branch' already exists but is fully merged (leftover from an earlier team) — replacing it"
      git -C "$project_dir" branch -D "$branch" >/dev/null
    else
      muster_die "branch '$branch' already exists with commits not merged into $(git -C "$project_dir" branch --show-current) — likely real work from an earlier run that never got cleaned up. Review it first (git -C \"$project_dir\" log $branch), then either merge it or remove it yourself (git -C \"$project_dir\" branch -D $branch), or pick a different instance name."
    fi
  fi

  mkdir -p "$(dirname "$path")"
  git -C "$project_dir" worktree add -q -b "$branch" "$path" HEAD
}

# muster_launch_agent <team> <project_dir> <workspace_id> <tab_id> <pane_id> <role> <name> <worktree_path> <branch> <model_override> <dry_run:0|1>
# Resolves the role's model/permission-mode/allowed-tools, starts claude in an
# already-placed pane (or logs what it would run, under --dry-run), and records
# the agent in team state. Placement (which workspace/tab/pane, worktree setup)
# is the caller's job — spawn-agent and team each place panes differently.
muster_launch_agent() {
  local team="$1" project_dir="$2" workspace_id="$3" tab_id="$4" pane_id="$5"
  local role="$6" name="$7" worktree_path="$8" branch="$9" model_override="${10}" dry_run="${11}"

  local model permission_mode allowed_tools
  model="${model_override:-$(muster_role_field "$role" model sonnet)}"
  permission_mode="$(muster_role_field "$role" permission-mode "")"
  allowed_tools="$(muster_role_field "$role" allowed-tools "")"

  local claude_args=(--agent "$role" --model "$model")
  [[ -n "$permission_mode" ]] && claude_args+=(--permission-mode "$permission_mode")
  [[ -n "$allowed_tools" ]] && claude_args+=(--allowed-tools "$allowed_tools")

  if [[ "$dry_run" == "1" ]]; then
    muster_log "[dry-run] would run: herdr agent start '$name' --kind claude --pane '$pane_id' -- ${claude_args[*]}"
  else
    muster_log "starting claude --agent $role ($model) in pane $pane_id"
    # A pane split right before launch (the normal case — team creates the
    # whole grid before starting anyone) briefly leaves it "agent_pane_busy"
    # in herdr even though it's really at a shell prompt; the very next
    # attempt succeeds. Retry a few times on that specific error before
    # giving up; any other error fails immediately.
    local attempt=1 max_attempts=5 result rc error_code
    while true; do
      # The `if` guards this from set -e: a bare `result=$(...)` assignment
      # would abort the whole script on the very first failure, before the
      # retry logic below ever ran.
      if result=$(herdr agent start "$name" --kind claude --pane "$pane_id" -- "${claude_args[@]}" 2>&1); then
        rc=0
      else
        rc=$?
      fi
      [[ $rc -eq 0 ]] && break
      error_code=$(jq -r '.error.code // empty' <<<"$result" 2>/dev/null)
      if [[ "$error_code" == "agent_pane_busy" && $attempt -lt $max_attempts ]]; then
        muster_log "pane $pane_id still settling after being split — retrying ($attempt/$max_attempts)"
        sleep 0.3
        attempt=$((attempt + 1))
        continue
      fi
      muster_die "failed to start claude in pane $pane_id: $result"
    done
  fi

  # --dry-run should have zero lasting effect. Recording it anyway would let
  # a later real run under the same team/instance name silently collide: the
  # state file would already exist pointing at the (fake/throwaway) dry-run
  # workspace, so the real run's actual workspace would never get tracked —
  # stop-team would close the wrong one and orphan the real one forever.
  [[ "$dry_run" == "1" ]] && return 0

  muster_record_agent "$team" "$project_dir" "$workspace_id" "$name" "$role" "$tab_id" "$pane_id" "$worktree_path" "$branch"
}

# muster_record_agent <team> <project_dir> <workspace_id> <name> <role> <tab_id> <pane_id> <worktree_path> <branch>
muster_record_agent() {
  local team="$1" project_dir="$2" workspace_id="$3" name="$4" role="$5" tab_id="$6" pane_id="$7" worktree_path="$8" branch="$9"
  local file tmp
  file="$(muster_state_file "$team")"
  if [[ ! -f "$file" ]]; then
    jq -n --arg team "$team" --arg ws "$workspace_id" --arg proj "$project_dir" \
          --arg ts "$(date -u +%FT%TZ)" \
      '{team_name:$team, workspace_id:$ws, project_dir:$proj, created_at:$ts, agents: []}' >"$file"
  fi
  tmp="$(mktemp)"
  jq --arg name "$name" --arg role "$role" --arg tab "$tab_id" --arg pane "$pane_id" \
     --arg wt "$worktree_path" --arg br "$branch" \
     '.agents += [{name:$name, role:$role, tab_id:$tab, pane_id:$pane, worktree_path:$wt, branch:$br}]' \
     "$file" >"$tmp" && mv "$tmp" "$file"
}
