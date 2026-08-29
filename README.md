# MusterAI

Shortcuts for spinning up teams of [Claude Code](https://claude.com/claude-code)
agents inside [herdr](https://herdr.dev), sized and specialized for whatever
you're working on. Not a CLI product — a thin layer of `just` recipes, agent
persona files, and team presets on top of two tools you already run.

```
muster team databricks-app-team     # orchestrator + react-developer + databricks-app-developer + tester-reviewer
muster team data-pipeline-team      # orchestrator + data-analyzer + data-engineer + sql-analytics-engineer
muster spawn data-engineer          # just one agent, on its own
muster stop-team <team-name>        # close its herdr workspace, remove its worktrees
```

## How it works

- Each **role** (`agents/*.md`) is a normal Claude Code subagent file — YAML
  frontmatter (`name`, `description`, `model`, plus MusterAI-specific
  `worktree`/`permission-mode`/`allowed-tools` fields) and a system prompt.
  `install.sh` symlinks these into `~/.claude/agents/` so `claude --agent
  <role>` can find them from any project, on any machine this repo is
  installed on.
- Every team member is a genuinely separate `claude` process, launched with
  `claude --agent <role>` into its own **herdr** pane (`herdr agent start
  ... --kind claude`). `just team <preset>` puts the whole team in one herdr
  workspace, **tiled as panes** in a single tab (round-robin binary splits,
  alternating right/down) so you can see everyone at a glance — use `herdr
  pane zoom` to punch into any one agent full-size and zoom back out. A tab
  holds at most 6 panes before staying legible gets questionable; a bigger
  team overflows into additional tabs in the same workspace. `just spawn
  <role>` on its own opens a new single-pane workspace.
- Roles that write files (`builder`, `data-engineer`, `react-developer`,
  `databricks-app-developer`, `sql-analytics-engineer`, `devops-infra`,
  `docs-writer`) get their own **git worktree** on a `muster/<name>` branch,
  so parallel agents never fight over the same files, and launch with
  `--permission-mode acceptEdits` so they don't stall waiting for edit
  approval in a pane you're not watching (Bash and other tool calls still
  prompt normally). Read/advisory roles (`orchestrator`, `planner`,
  `data-analyzer`, `tester-reviewer`) work directly in the main checkout.
- `orchestrator` additionally gets `--allowed-tools "Bash(herdr *)"`, so it
  can dispatch to and monitor teammate panes itself (`herdr agent prompt
  <name> "<task>" --wait`) instead of just being a planning persona you drive
  by hand.
- Team state (which herdr workspace, which panes, which worktrees) is
  tracked in `~/.muster/teams/<team-name>.json` — that's what `stop-team`
  reads to tear things down, and what it checks before removing a worktree
  with uncommitted or unmerged work.

## Roles

| role | model | worktree | notes |
|---|---|---|---|
| `orchestrator` | opus | no | dispatches/monitors via herdr |
| `planner` | opus | no | plans, doesn't implement |
| `builder` | sonnet | yes | general implementation |
| `tester-reviewer` | haiku | no | verifies, doesn't fix |
| `data-analyzer` | sonnet | no | exploratory, read-only |
| `data-engineer` | opus | yes | pipelines, Databricks/Spark |
| `react-developer` | opus | yes | frontend |
| `databricks-app-developer` | opus | yes | Databricks Apps backend + integration (AppKit: Node.js/TS) |
| `sql-analytics-engineer` | sonnet | yes | warehouse SQL models, metrics |
| `devops-infra` | sonnet | yes | CI/CD, Asset Bundles, infra |
| `docs-writer` | haiku | yes | README/CONTEXT.md/ADRs |

## Team presets

`teams/*.yaml` — `planner-builder-tester`, `databricks-app-team`,
`data-pipeline-team`, `full-stack-team`. `just team <name>` also accepts an
ad hoc comma-separated role list instead of a preset name (repeat a role for
more than one instance): `just team builder,builder,tester-reviewer`.

## Setup

Requires `claude`, `herdr`, `just`, `yq`, `jq`, `git` on PATH.

```
just install
```

Symlinks `agents/*.md` into `~/.claude/agents/`, and adds a `muster()` shell
function to your `.zshrc`/`.bashrc` so the commands above work from inside
any project directory — not just this repo. Re-running is safe (idempotent).

At work (WSL, Claude Enterprise): `git clone` this repo, run `just install`
the same way. **One thing to verify there**: Claude Code's agent-discovery
priority puts org-managed settings above project/user `.claude/agents/`
definitions — if your Enterprise admin has managed agent settings configured,
they could shadow these role files. Check `claude doctor` or your org's
managed settings if a role doesn't behave as expected.

## Direct primitive

`spawn-agent`/`team`/`stop-team` in `bin/` are plain bash and can be run
without `just`/the `muster` wrapper if you want to script around them
directly. All three accept `--dry-run` (prints what would happen, including
the exact `herdr agent start` command, without launching a real `claude`
process).
