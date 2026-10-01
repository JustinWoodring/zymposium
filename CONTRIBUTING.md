# Contributing to zymposium

Thanks for your interest in improving zymposium. This document describes how to
get a change merged.

## Reporting issues

Open an issue at <https://github.com/JustinWoodring/zymposium/issues> and
include:

- Your OS and architecture (for example, `x86_64-linux`, `aarch64-macos`,
  `x86_64-windows`).
- The `zig version` you are using.
- The exact `zymposium` command you ran and its full output.
- The output of `zymposium doctor`, which lists any broken or orphaned skill
  links, and `zymposium list`, which records where each skill came from.
  Redact anything sensitive.
- Whether [zest](https://github.com/JustinWoodring/zest) is installed
  (`zest list`), since that changes where skills are discovered.

## Getting set up

```sh
git clone https://github.com/JustinWoodring/zymposium
cd zymposium
zig build            # build zig-out/bin/zymposium
zig build test       # unit tests
```

Requirements: Zig 0.16.0 or newer, plus `git`. You do not need a separate Zig
install or a network connection for the test suites; the hermetic suite uses
local fixtures.

## zest is optional

zymposium is complete on its own. With no tool manager installed it still walks
the project's dependency chain, links skills into every configured agent
boundary, records provenance, and verifies links with `doctor`.

Reading the manifest of an installed CLI tool is the **only** feature that
depends on zest, and it must stay additive:

- A missing or malformed zest tree must never fail a command. `gather` in
  `src/commands.zig` treats a missing root as an empty source list and an
  unreadable `state.json` as a warning, not an error.
- Nothing in `src/project.zig` or `src/packages.zig` may reach for zest. Those
  two sources are the tool-independent core; if you find yourself wanting zest
  state there, the feature belongs in a source of its own.

## Skills the tools ship

The two self-skills have different owners: zymposium's source is
`zymposium/skills/zymposium/SKILL.md`, while zest's source is
`zest/skills/zest/SKILL.md`. **Do not add zest's skill under this repository.**
When zest has been installed, `src/self.zig` locates its staged source at
`<XDG_DATA_HOME>/zest/self/src`; without zest, the zest skill is simply absent.

zymposium's own skill is located by walking up from its running executable to
the nearest `build.zig.zon`, so a from-source build can provision it without
any manifest or configuration.

Two consequences worth remembering:

- `skills` must stay in both repositories' `build.zig.zon` `.paths`. Drop it
  and `zig fetch` or `zest install` silently strips the skills.
- Do not move a from-source zymposium binary out of its tree expecting
  self-discovery to follow. A bare copy in a `bin` directory with no
  `build.zig.zon` above it simply has no self-skills, which is fine and silent
  by design.

## Development workflow

Run these before opening a pull request:

```sh
zig build                 # must build with no warnings
zig build test            # unit tests
zig fmt --check src build.zig
./scripts/mock-e2e.sh     # hermetic end-to-end suite (no network)
```

CI runs ShellCheck and verifies installation through `zest install` on Linux.
Unit tests, builds, format checks, and the hermetic end-to-end suite run on
Linux, macOS, and Windows. Successful pushes to `main` publish the site to
`gh-pages`; set repository Settings → Pages → Build and deployment → Source to
**Deploy from a branch**, `gh-pages` / `/`, once.

## Code style

zymposium follows the conventions of the Zig standard library and the Zig
project:

- Format with the canonical `zig fmt`; CI rejects unformatted code.
- Use 4 spaces of indentation. Never use tabs.
- Prefer `const` over `var`, and `orelse`/`catch` over branching where they
  read better.
- Keep public declarations documented with `///` comments that explain *why*,
  not *what*. Every source file carries a copyright and `SPDX-License-Identifier`
  header.
- Keep the tool boring: no clever metaprogramming, no hidden global state, and
  no new dependencies without discussion.
- Errors that a user can act on are printed to stderr with a `zymposium: `
  prefix and turned into a specific exit code. Do not let internal Zig errors
  escape as `internal error:` unless they are genuinely bugs.

## The safety rules

These are the invariants the project exists to keep. A change that breaks one
of them is a bug even if it passes every test:

- **Never delete a path that is not in the manifest.** zymposium owns the links
  it records in `state.json` and nothing else. A hand-written skill sitting
  beside a provisioned one must survive every sync.
- **Decide from what is on disk, not only from what the manifest claims.** A
  real directory where the manifest records a symlink means the user replaced
  it; that is a conflict, never a silent delete. See `decide` in
  `src/provision.zig`, which has a regression test for exactly this.
- **Provider namespaces isolate same-named skills.** Each target is
  `<agent-skills>/<provider>/<skill>`, and each manifest entry is keyed by
  provider plus skill. Two packages shipping the same skill name are both
  provisioned; they cannot overwrite one another.
- **Scope pruning.** A `--tool` run touches only that provider's skills. A full
  run is responsible for everything, which is why it prunes links whose tool or
  dependency has disappeared.

## Tests

Every behavior change needs a test. Tests live next to the code they cover as
`test` blocks, except end-to-end behavior, which belongs in
`scripts/mock-e2e.sh`.

- Unit tests must be hermetic: no network, no filesystem outside a temp dir,
  no reliance on the host toolchain layout. `std.testing.tmpDir` and
  `std.testing.io` give you both.
- Ownership rules are easy to get wrong and are worth stating explicitly. Every
  allocation a function returns needs a matching `deinit`, and tests run with
  `std.testing.allocator` will tell you when you have leaked or double-freed.
- New CLI behavior should be covered by the e2e suite. New agent support needs
  a row in `src/agents.zig` and its test.
- Prefer a test that fails for the right reason over one that merely exercises
  a code path.

## Adding an agent

To provision into another agent's skill directory:

1. Add an entry to `all` in `src/agents.zig` with a stable `id`, a display name,
   and the global and project-relative `skills` directories.
2. Add the id to `default_ids` if it should be on by default.
3. Extend the tests in `src/agents.zig`.

If the agent needs different handling than "a directory of skills", open an
issue first — the engine is deliberately built around that one shape.

## Pull requests

1. Fork the repository and create a topic branch.
2. Make your change with tests, and make sure `zig build test`,
   `zig fmt --check src build.zig`, and `./scripts/mock-e2e.sh` all pass.
3. Update `README.md` if you change user-visible behavior.
4. Open a pull request describing the motivation and the approach. Keep the
   change focused; unrelated cleanups belong in their own commit.
5. CI must be green on Linux, macOS, and Windows before merge.

## Versioning and releases

`main` is the development branch. Releases are made by the maintainer by
pushing an annotated `vX.Y.Z` tag. Contributors do not push tags or releases;
open a pull request instead.

Before tagging, set the same version in `.version` in `build.zig.zon` and the
`version` constant in `src/cli.zig`. The `v*` release workflow checks this
match, cross-builds the supported platform archives, and creates the GitHub
release with generated notes.

## Licensing

By contributing you agree that your contributions are licensed under the MIT
license that covers this project. Add your name to [CONTRIBUTORS](CONTRIBUTORS)
if you would like to be credited.
