# Claude Code project instructions

This project uses a single, agent-agnostic instruction file for both Claude Code
and Codex. The canonical project rules are imported below.

@AGENTS.md

## Shared skills

Reusable playbooks live under [`.agents/skills/`](.agents/skills) and are shared between
agents:

- `.codex/skills/` → symlink to `.agents/skills/` (so Codex finds them)
- `.claude/skills/` → symlink to `.agents/skills/` (so Claude Code finds them)

Add new shared skills under `.agents/skills/<name>/SKILL.md` (front matter:
`name`, `description`). Update both agents at once by editing one file.
