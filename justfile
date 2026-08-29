# MusterAI — shortcuts for spinning up teams of Claude Code agents in herdr.
#
# After `just install`, use the `muster` shell function from any project
# directory instead of typing `just --justfile ... --working-directory .`
# yourself. See README.md.

muster_home := justfile_directory()

# List available roles.
roles:
    @ls "{{muster_home}}/agents" | sed 's/\.md$//'

# Walk through common commands with real examples, for learning/practice.
examples:
    @"{{muster_home}}/bin/examples"

# List currently active teams (or `just teams <name>` for one team's agent detail).
teams name="":
    @"{{muster_home}}/bin/teams" "{{name}}"

# List available team presets.
presets:
    @for f in "{{muster_home}}"/teams/*.yaml; do \
        printf '%-24s ' "$(basename "$f" .yaml)"; \
        yq -r '.description' "$f"; \
    done

# Spawn a single agent (role) as its own herdr workspace. Run from inside your target project.
spawn role name="" *args:
    @"{{muster_home}}/bin/spawn-agent" "{{role}}" "{{name}}" {{args}}

# Spin up a team: `just team databricks-app-team` or `just team builder,tester-reviewer`.
team spec team_name="" *args:
    @"{{muster_home}}/bin/team" "{{spec}}" "{{team_name}}" {{args}}

# Tear down a team: closes its herdr workspace and removes its worktrees.
stop-team name *args:
    @"{{muster_home}}/bin/stop-team" "{{name}}" {{args}}

# One-time setup: symlink agent roles, check dependencies, wire up `muster`.
install:
    @"{{muster_home}}/install.sh"
