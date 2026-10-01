---
name: zymposium
description: Provision and troubleshoot agent skills with zymposium. Use when adding skills to a package, syncing them into an agent, updating or removing a provisioned skill, or debugging a skill that is not appearing in an agent.
---

# zymposium

zymposium finds agent skills declared in `<package-root>/skills/` and links them
into the directories your agent actually reads (`~/.claude/skills`,
`~/.codex/skills`, `~/.agent/skills`, and the project-local equivalents).

It is useful when you are packaging a Zig library or a CLI tool that has
non-obvious usage rules worth encoding as a skill.

## Adding a skill to a package

A skill is a directory under `skills/` containing a `SKILL.md`:

```
my-package/
└── skills/
    └── my-package-usage/
        ├── SKILL.md
        └── reference.md
```

```markdown
---
name: my-package-usage
description: How to use my-package correctly
---

Body goes here.
```

The **directory name** is the skill's identity — that is the name the agent
resolves. The `description` is what an agent reads to decide whether to open the
skill, so write it for that decision: say when the skill is relevant, not what it
contains.

Add `skills` to the package's `build.zig.zon` `.paths`, otherwise `zig fetch`
and `zest install` will not carry it.

## Commands

```sh
zymposium sources     # what is available, before provisioning it
zymposium sync        # provision everything
zymposium list        # what is provisioned, and where each skill came from
zymposium doctor      # find broken, dangling, or orphaned links
zymposium remove <provider/skill>    # bare name works only when unique
```

Use `--json` on `sync`, `list`, `sources`, and `doctor` when scripting.

## Where skills come from

- **Project dependencies** — the transitive `build.zig.zon` graph of the project
  you are in. This is what you get with no tool manager installed.
- **zest tools** — CLI tools installed by [zest](https://github.com/JustinWoodring/zest),
  read from its install manifest. Requires zest; refreshed by `zest update`.
- **Added packages** — `zymposium add <path|url>`.

Non-git dependencies (plain tarball URLs) are reported and skipped.

## Behavior worth knowing

- Skills are **symlinked**, not copied, so updating the source package updates
  every agent at once. `link_mode` in the config can force a real copy.
- zymposium **never deletes a path it did not create**. A hand-written skill
  beside a provisioned one is safe.
- Replacing a provisioned symlink with your own directory is reported as a
  conflict and left alone. Pass `--force` to take it over.
- Install targets are namespaced as `<agent-skills>/<provider>/<skill>`, so two
  packages can ship the same skill name without colliding. Use
  `zymposium update <provider>/<skill>` or `remove <provider>/<skill>` when a
  bare skill name matches more than one provider.
- `doctor` exits non-zero when it finds a problem; `sync` usually repairs it.

## Configuration

`~/.config/zymposium/config.json`:

```json
{
  "version": 1,
  "agents": ["claude", "codex", "agent"],
  "link_mode": "auto",
  "scope": "both"
}
```

An unknown agent id is a hard error rather than a silent no-op, so a typo cannot
quietly provision nothing. Run `zymposium agents` for the current registry.

## When a skill does not appear

1. `zymposium sources` — is the package listed at all? If not, it is not being
   discovered: check the `skills/` directory name and `build.zig.zon` `.paths`.
2. `zymposium sync` — read the summary. `conflict:` lines mean something else
   already holds that name, and nothing was written.
3. `zymposium doctor` — a `missing` link was deleted, `dangling` points at the
   wrong place, `orphaned` means the source package is gone.
4. If the package is a dependency, confirm you ran `sync` inside the project —
   project scope is discovered by walking up from the current directory.
