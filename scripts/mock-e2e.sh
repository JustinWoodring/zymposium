#!/bin/sh
# Hermetic end-to-end test harness for zymposium. No network access required:
# every "remote" is a local git fixture, the zest tree is faked on disk, and
# every environment variable that reaches the real user home is redirected.
# Runs on Linux, macOS, and Windows (Git Bash).
#
# Usage: scripts/mock-e2e.sh   (run `zig build` first)
#
# Copyright (c) 2026 Justin Woodring <jwoodrg@gmail.com>
#
# SPDX-License-Identifier: MIT
set -eu

UNAME=$(uname -s)
case "$UNAME" in
    MINGW*|MSYS*|CYGWIN*) WIN=1 ;;
    *) WIN= ;;
esac
EXE=${WIN:+.exe}

# shellcheck disable=SC1007  # CDPATH= prefix is deliberate
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZYM="$REPO/zig-out/bin/zymposium$EXE"
[ -x "$ZYM" ] || { echo "mock-e2e: build first: zig build" >&2; exit 1; }

WORK=$(mktemp -d)
if [ -n "$WIN" ]; then WORK=$(cygpath -m "$WORK"); fi

LOG="$WORK/last.log"
TRANSCRIPT="$WORK/transcript.txt"
PASS=0

cleanup() {
    code=$?
    if [ "$code" != 0 ]; then
        printf '\n--- transcript ---\n' >&3 || :
        cat "$TRANSCRIPT" >&3 2>/dev/null || :
        if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
            {
                printf '### mock-e2e failure (exit %s)\n\n```text\n' "$code"
                cat "$TRANSCRIPT"
                printf '```\n'
            } >>"$GITHUB_STEP_SUMMARY" || :
        fi
        printf '::error title=mock-e2e::failed (exit %s); transcript added to job summary\n' "$code" >&3 || :
    fi
    [ "${ZYM_KEEP:-}" = 1 ] || rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# Capture the full transcript so a CI failure is diagnosable from the log
# alone; original stderr (fd 3) is preserved for ::error:: annotations.
exec 3>&2 4>&1
exec > "$TRANSCRIPT" 2>&1

# The home directory is part of the fixture: zymposium resolves every global
# agent skill directory from $HOME, so a run that inherited the real one would
# write into the developer's ~/.claude.
export HOME="$WORK/home"
export XDG_DATA_HOME="$WORK/xdg/data"
export XDG_CONFIG_HOME="$WORK/xdg/config"
# git must never block on a credential prompt: every clone is file://.
export GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"

CONFIG="$XDG_CONFIG_HOME/zymposium/config.json"
STATE="$XDG_DATA_HOME/zymposium/state.json"
PKGS="$XDG_DATA_HOME/zymposium/packages.json"
DEPS="$XDG_DATA_HOME/zymposium/deps"
ZEST_ROOT="$XDG_DATA_HOME/zest"
ZEST_STATE="$ZEST_ROOT/state.json"

# `sync` walks the dependency graph of the nearest ancestor holding a
# build.zig.zon. Running from the repository would therefore pull that
# project's real dependencies off the network, so every command starts from a
# scratch directory that has no project above it, and the two project-scope
# checks move into their fixtures explicitly.
NEUTRAL="$WORK/neutral"
mkdir -p "$NEUTRAL"

ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() {
    printf 'not ok - %s\n' "$1" >&2
    [ "${2:-}" = "" ] || printf '%s\n' "$2" >&2
    exit 1
}

# assert_exit <want-code> <desc> <cmd...>
assert_exit() {
    want=$1; desc=$2; shift 2
    set +e; "$@" >"$LOG" 2>&1; got=$?; set -e
    [ "$got" = "$want" ] || fail "$desc" "exit $got (want $want); log: $(cat "$LOG")"
}
assert_ok() { desc=$1; shift; assert_exit 0 "$desc" "$@"; ok "$desc"; }
assert_fails() { desc=$1; shift; assert_exit 1 "$desc" "$@"; ok "$desc"; }
assert_grep() { # <desc> <pattern> <file>
    grep -q -- "$2" "$3" || fail "$1" "pattern '$2' not found in $3: $(cat "$3")"
}
assert_absent() { # <desc> <pattern> <file>
    if grep -q -- "$2" "$3"; then
        fail "$1" "pattern '$2' unexpectedly present in $3: $(cat "$3")"
    fi
}
# A --json document must be an object, not a rendered table with a stray key.
assert_json() { # <desc> <expected-key> <file>
    case $(head -c 1 "$3") in
        '{') ;;
        *) fail "$1" "$3 is not a JSON object: $(cat "$3")" ;;
    esac
    grep -q -- "\"$2\"" "$3" || fail "$1" "key \"$2\" missing from $3: $(cat "$3")"
    ok "$1"
}
# Notice lines go to stderr while results go to stdout, and two writers sharing
# one log file overwrite each other; capture stderr alone when it is the thing
# under test.
assert_stderr_grep() { # <desc> <pattern> <cmd...>
    desc=$1; pattern=$2; shift 2
    set +e; "$@" >/dev/null 2>"$LOG"; got=$?; set -e
    [ "$got" = 0 ] || fail "$desc" "exit $got (want 0); log: $(cat "$LOG")"
    grep -q -- "$pattern" "$LOG" || fail "$desc" "pattern '$pattern' not found in stderr: $(cat "$LOG")"
    ok "$desc"
}

# git clone URL for a fixture path, native per host.
fileurl() {
    if [ -n "$WIN" ]; then
        printf 'file:///%s' "$(cygpath -m "$1")"
    else
        printf 'file://%s' "$1"
    fi
}

# skill <skills-dir> <name> <description>
skill() {
    mkdir -p "$1/$2"
    cat >"$1/$2/SKILL.md" <<EOF
---
name: $2
description: $3
---

# $2

Fixture skill for mock-e2e.
EOF
}

# gitfix <dir>: turn a fixture directory into a repository. The identity is
# passed inline so the harness never reads or writes a real ~/.gitconfig.
gitfix() {
    (cd "$1" && git init -q -b main && git add -A &&
        git -c user.email=t@t -c user.name=t commit -qm init)
}

# A provisioned skill is normally a symlink. On Windows without symlink
# privileges, `auto` intentionally falls back to a real directory copy.
# Assert the target when symlinks work, and a usable skill directory otherwise.
 assert_skill_link() { # <path> <expected-target-suffix> <desc>
    if [ -L "$1" ]; then
        target=$(readlink "$1")
        if [ -n "$WIN" ]; then target=$(cygpath -u "$target"); fi
        case "$target" in
            *"$2") ;;
            *) fail "$3" "$1 points at '$target', which does not end in '$2'" ;;
        esac
    elif [ -n "$WIN" ] && [ -d "$1" ] && [ -f "$1/SKILL.md" ]; then
        : # documented symlink fallback on Windows without symlink privileges
    else
        fail "$3" "$1 is neither the expected symlink nor a usable copy"
    fi
}

F="$WORK/fixtures"

# ---------------------------------------------------------------------------
# CLI basics
# ---------------------------------------------------------------------------
cd "$NEUTRAL"

out=$("$ZYM" --version)
printf '%s' "$out" | grep -q "zymposium 0.1.0" || fail "--version" "$out"
ok "--version reports the version"

assert_exit 2 "unknown command exits 2" "$ZYM" frobnicate
ok "unknown command exits 2"

assert_exit 2 "stray flag exits 2" "$ZYM" list --bogus
ok "stray flag is a usage error"

assert_ok "help" "$ZYM" help
assert_grep "help prints usage" "Usage:" "$LOG"
assert_grep "help lists the sync command" "zymposium sync" "$LOG"
ok "help prints the usage text"

# ---------------------------------------------------------------------------
# init: config plus the global agent boundaries
# ---------------------------------------------------------------------------
assert_ok "init" "$ZYM" init
assert_grep "config records claude" '"claude"' "$CONFIG"
assert_grep "config records codex" '"codex"' "$CONFIG"
assert_grep "config records agent" '"agent"' "$CONFIG"
for d in .claude .codex .agent; do
    [ -d "$HOME/$d/skills" ] || fail "init creates $d/skills" "$HOME/$d/skills missing"
done
ok "init writes config.json and creates the global skill directories"

assert_ok "agents" "$ZYM" agents
assert_grep "agents marks the enabled ones" "\* enabled in config.json" "$LOG"
assert_grep "agents lists Claude Code" "Claude Code" "$LOG"
ok "agents lists every known agent"

# ---------------------------------------------------------------------------
# A hand-written skill must survive every later sync: zymposium only deletes
# paths recorded in its own manifest.
# ---------------------------------------------------------------------------
mkdir -p "$HOME/.claude/skills/handwritten"
printf 'name: handwritten\n' >"$HOME/.claude/skills/handwritten/SKILL.md"

# ---------------------------------------------------------------------------
# zest tools: discovery, symlinking, provenance
mkdir -p "$ZEST_ROOT/src/zest-tool/skills" "$ZEST_ROOT/src/plain-tool"
skill "$ZEST_ROOT/src/zest-tool/skills" zst-alpha "Alpha skill from a zest tool"
skill "$ZEST_ROOT/src/zest-tool/skills" zst-beta "Beta skill from a zest tool"
cat >"$ZEST_STATE" <<EOF
{
  "version": 1,
  "tools": {
    "zest-tool": {
      "source_url": "https://example.com/zest-tool",
      "version": "v1.2.0",
      "commit": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "installed_binary": "/usr/local/bin/zest-tool",
      "installed_at": "2026-09-29T16:26:00Z"
    },
    "plain-tool": {
      "source_url": "https://example.com/plain-tool",
      "version": "v0.1.0",
      "commit": "abc123",
      "installed_binary": "/usr/local/bin/plain-tool",
      "installed_at": "2026-09-29T16:26:00Z"
  }
  }
}
EOF

# A tool that ships no skills/ directory has nothing to offer, so listing it
# would advertise a provider with nothing behind it.
assert_ok "sources" "$ZYM" sources
assert_grep "sources header" "PROVIDER.*KIND.*VERSION.*SKILLS.*ORIGIN" "$LOG"
assert_grep "sources shows the tool" "zest-tool" "$LOG"
assert_grep "sources labels the kind" "zest_tool" "$LOG"
assert_grep "sources counts offered skills" "2 (0)" "$LOG"
assert_absent "sources omits skillless tools" "plain-tool" "$LOG"

assert_ok "sync provisions the zest tool" "$ZYM" sync
assert_grep "sync reports what it linked" "linked 9, updated 0, unchanged 0, removed 0" "$LOG"
for d in .claude .codex .agent; do
    for s in zst-alpha zst-beta; do
        assert_skill_link "$HOME/$d/skills/zest-tool/$s" "/skills/$s" "$d/$s is a symlink to the skill dir"
    done
done
ok "sync symlinks every discovered skill into all three agents"

[ -f "$HOME/.claude/skills/handwritten/SKILL.md" ] ||
    fail "hand-written skills are never touched" "handwritten/SKILL.md was removed"
ok "hand-written skills survive provisioning"

assert_grep "state records the provider" '"provider": "zest-tool"' "$STATE"
assert_grep "state records the source kind" '"source_kind": "zest_tool"' "$STATE"
assert_grep "state records link ownership" '"path"' "$STATE"
ok "state.json records provenance and owned paths"

assert_ok "list shows provenance" "$ZYM" list
assert_grep "list header" "SKILL.*PROVIDER.*VERSION.*AGENTS.*DESCRIPTION" "$LOG"
assert_grep "list names the source" "from    https://example.com/zest-tool" "$LOG"
assert_grep "list names the update command" "update  zymposium update zest-tool/zst-alpha" "$LOG"
assert_grep "list shows the global link" "link    claude ~/.claude/skills/zest-tool/zst-alpha (global)" "$LOG"
ok "list explains where each skill came from and how to update it"

# A second sync must be a no-op: churning links on every run would make the
# tool look like it is doing something when it is not.
assert_ok "second sync" "$ZYM" sync
assert_grep "second sync changes nothing" "linked 0, updated 0, unchanged 9, removed 0" "$LOG"
ok "sync is idempotent"

assert_ok "doctor is healthy" "$ZYM" doctor
CONFLICT_PATH="$HOME/.claude/skills/zest-tool/zst-alpha"
if [ -L "$CONFLICT_PATH" ]; then
    rm "$CONFLICT_PATH"
    mkdir -p "$CONFLICT_PATH"
    printf 'my own notes\n' >"$CONFLICT_PATH/NOTES.md"

    assert_fails "sync reports the conflict" "$ZYM" sync
    expected_conflict=$CONFLICT_PATH
    conflict_log=$LOG
    if [ -n "$WIN" ]; then
        expected_conflict=$(printf '%s\n' "$CONFLICT_PATH" | tr '\134' '/')
        conflict_log="$WORK/path-normalized.log"
        tr '\134' '/' <"$LOG" >"$conflict_log"
    fi
    grep -Fq -- "conflict: $expected_conflict" "$conflict_log" ||
        fail "conflict is named" "path '$expected_conflict' not found: $(cat "$LOG")"
    ok "conflict is named"
    assert_grep "conflict names both parties" "is held by" "$LOG"
    [ -f "$CONFLICT_PATH/NOTES.md" ] ||
        fail "conflict leaves user data alone" "NOTES.md was deleted by a conflicting sync"
    ok "a directory replacing our symlink is a conflict, not a delete"

    assert_ok "--force takes the path over" "$ZYM" sync --force
    assert_skill_link "$CONFLICT_PATH" "/skills/zst-alpha" "forced path is restored"
    ok "--force replaces a path the user had taken over"
elif [ -n "$WIN" ] && [ -d "$CONFLICT_PATH" ]; then
    # A recorded Windows copy is indistinguishable from a user-edited copy, so
    # sync must keep it as-is rather than overwrite the user's additions.
    printf 'my own notes\n' >"$CONFLICT_PATH/NOTES.md"
    assert_ok "sync keeps edits in a copied skill" "$ZYM" sync
    [ -f "$CONFLICT_PATH/NOTES.md" ] || fail "copy edits survive" "NOTES.md disappeared"
    ok "Windows copy fallback preserves user edits"
else
    fail "provisioned skill has a supported materialization" "$CONFLICT_PATH missing"
fi

# doctor names what it found broken, so `sync` is not the only repair path.
rm -rf "$HOME/.codex/skills/zest-tool/zst-beta"
assert_fails "doctor reports a missing link" "$ZYM" doctor
assert_grep "doctor names the kind" "missing" "$LOG"
assert_grep "doctor names the skill" "zst-beta" "$LOG"
ok "doctor reports a link that disappeared"

assert_ok "sync repairs the missing link" "$ZYM" sync
assert_ok "doctor healthy again" "$ZYM" doctor
assert_grep "doctor clean after repair" "all provisioned skills are healthy" "$LOG"
ok "sync repairs what doctor found"

# ---------------------------------------------------------------------------
# Pruning: a tool removed by zest takes its skills with it.
# ---------------------------------------------------------------------------
rm -rf "$ZEST_ROOT/src/zest-tool"
assert_ok "sync after the tool is gone" "$ZYM" sync
assert_grep "sync prunes the dropped skills" "linked 0, updated 0, unchanged 3, removed 2" "$LOG"
[ ! -e "$HOME/.claude/skills/zest-tool/zst-alpha" ] || fail "pruned link removed" "zst-alpha still linked"
[ ! -e "$HOME/.agent/skills/zest-tool/zst-beta" ] || fail "pruned link removed" "zst-beta still linked"
assert_absent "state forgets the pruned skills" "zst-alpha" "$STATE"
ok "skills of a removed tool are unlinked and forgotten"

# ---------------------------------------------------------------------------
# Project scope: transitive path dependencies, linked globally and locally
# ---------------------------------------------------------------------------
APP="$F/app"
mkdir -p "$F/dep-a/skills" "$F/dep-b/skills" "$APP"
skill "$F/dep-a/skills" dep-a-skill "Skill shipped by dep-a"
skill "$F/dep-b/skills" dep-b-skill "Skill shipped by dep-b"
cat >"$F/dep-b/build.zig.zon" <<'EOF'
.{
    .name = .dep_b,
    .version = "0.1.0",
    .fingerprint = 0x9b9e4a0c1b2d3e4f,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{""},
}
EOF
# The graph must be followed transitively: dep-b is only reachable through
# dep-a, so a walk that stops at direct dependencies misses it entirely.
cat >"$F/dep-a/build.zig.zon" <<'EOF'
.{
    .name = .dep_a,
    .version = "0.1.0",
    .fingerprint = 0x8a8e4a0c1b2d3e4f,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .dep_b = .{ .path = "../dep-b" },
    },
    .paths = .{""},
}
EOF
cat >"$APP/build.zig.zon" <<'EOF'
.{
    .name = .fixture_app,
    .version = "0.1.0",
    .fingerprint = 0x7a7e4a0c1b2d3e4f,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .dep_a = .{ .path = "../dep-a" },
    },
    .paths = .{""},
}
EOF

cd "$APP"
assert_ok "sync inside a project" "$ZYM" sync
assert_ok "sources inside a project" "$ZYM" sources
cd "$NEUTRAL"
assert_grep "project dep is a source" "dep-a" "$LOG"
assert_grep "path deps are project_dep" "project_dep" "$LOG"
assert_grep "transitive dep is a source" "dep-b" "$LOG"
ok "sources walks the dependency graph transitively"

assert_skill_link "$HOME/.claude/skills/dep_a/dep-a-skill" "/skills/dep-a-skill" "global link"
assert_skill_link "$HOME/.claude/skills/dep_b/dep-b-skill" "/skills/dep-b-skill" "global link"
assert_skill_link "$APP/.claude/skills/dep_a/dep-a-skill" "/skills/dep-a-skill" "project link"
assert_skill_link "$APP/.claude/skills/dep_b/dep-b-skill" "/skills/dep-b-skill" "project link"
assert_skill_link "$APP/.agent/skills/dep_b/dep-b-skill" "/skills/dep-b-skill" "project link"
ok "project dependencies are linked globally and project-locally"

# ---------------------------------------------------------------------------
# A git dependency is cloned into the cache; a non-git one is only reported.
# ---------------------------------------------------------------------------
GITDEP="$F/gitdep"
mkdir -p "$GITDEP/skills"
skill "$GITDEP/skills" git-skill "Skill shipped by a git dependency"
gitfix "$GITDEP"

APP2="$F/app-git"
mkdir -p "$APP2"
cat >"$APP2/build.zig.zon" <<EOF
.{
    .name = .fixture_app_git,
    .version = "0.1.0",
    .fingerprint = 0x6a6e4a0c1b2d3e4f,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{
        .gitdep = .{ .url = "$(fileurl "$GITDEP")", .hash = "1220-0000" },
        .archive = .{ .url = "https://example.com/x.tar.gz", .hash = "1220-0000" },
    },
    .paths = .{""},
}
EOF

cd "$APP2"
# One dependency that cannot be cloned must not cost the user the others, so
# the run still exits 0 and only prints a notice. stderr is captured on its
# own: stdout and stderr write the shared log from separate file offsets, so a
# merged capture can hide one of them.
assert_stderr_grep "non-git dependency is reported" "not a git URL" "$ZYM" sync
assert_ok "sync again in the project" "$ZYM" sync
assert_grep "git dependency is provisioned once" "linked 0, updated 0, unchanged 12, removed 0" "$LOG"
cd "$NEUTRAL"

# shellcheck disable=SC2086  # deliberate glob: no match must leave a literal
set -- "$DEPS"/gitdep-*
[ -d "$1" ] || fail "git dependency is cloned into the cache" "no gitdep-* under $DEPS: $(ls "$DEPS")"
assert_skill_link "$HOME/.claude/skills/gitdep/git-skill" "/skills/git-skill" "git dep skill is linked"
cd "$APP2"
assert_ok "sources with a git dependency" "$ZYM" sources
cd "$NEUTRAL"
assert_grep "git dependency is a project_dep" "project_dep" "$LOG"
assert_grep "git dependency is provisioned" "1 (1)" "$LOG"
ok "a git dependency is cloned, cached, and its skills linked"

# --offline must reuse the cache and never reach out; with the cache gone the
# dependency simply drops out of the run.
rm -rf "$DEPS"/gitdep-*
cd "$APP2"
assert_ok "offline sync" "$ZYM" sync --offline
cd "$NEUTRAL"
[ ! -e "$HOME/.claude/skills/gitdep/git-skill" ] ||
    fail "offline never fetches" "the cached clone was recreated without --offline"
ok "--offline uses only what is already cached"

cd "$APP2"
assert_ok "sync re-fetches the dependency" "$ZYM" sync
cd "$NEUTRAL"
assert_skill_link "$HOME/.claude/skills/gitdep/git-skill" "/skills/git-skill" "re-fetched git dep skill"
ok "a later online sync restores the dependency's skills"

# ---------------------------------------------------------------------------
# zymposium add: the third source kind
# ---------------------------------------------------------------------------
LOCAL="$F/local-pkg"
mkdir -p "$LOCAL/skills"
skill "$LOCAL/skills" local-skill "Skill from an added package"


assert_ok "add a local package" "$ZYM" add "$LOCAL"
assert_grep "add reports the package" "added local-pkg" "$LOG"
assert_grep "packages.json records the package" '"local-pkg"' "$PKGS"
assert_skill_link "$HOME/.claude/skills/local-pkg/local-skill" "/skills/local-skill" "added skill is linked"
assert_ok "sources after add" "$ZYM" sources
assert_grep "added package kind" "package" "$LOG"
assert_grep "added package appears" "local-pkg" "$LOG"
ok "add registers a package, links its skills, and runs a sync"

assert_fails "adding a missing path fails" "$ZYM" add "$F/no-such-package"
assert_grep "missing path is explained" "is not a directory" "$LOG"

# --tool is how a package manager provisions one provider at a time; scoping it
# must not prune the links belonging to anyone else.
assert_ok "scoped sync" "$ZYM" sync --tool local-pkg
assert_skill_link "$HOME/.claude/skills/local-pkg/local-skill" "/skills/local-skill" "scoped link"
assert_skill_link "$HOME/.claude/skills/gitdep/git-skill" "/skills/git-skill" "other provider's link"
assert_grep "scoped sync keeps other providers in state" '"provider": "gitdep"' "$STATE"
ok "sync --tool leaves every other provider's skills alone"

# Same-named skills from different packages are distinct because installation
# namespaces the target by provider. A flat `<skills>/<name>` target would make
# this conflict and silently hide one package's guidance.
LOCAL2="$F/local-pkg2"
mkdir -p "$LOCAL2/skills"
skill "$LOCAL2/skills" local-skill "Same skill name, different package"
assert_ok "add second package with same skill name" "$ZYM" add "$LOCAL2"
assert_skill_link "$HOME/.claude/skills/local-pkg/local-skill" "/skills/local-skill" "first provider namespace"
assert_skill_link "$HOME/.claude/skills/local-pkg2/local-skill" "/skills/local-skill" "second provider namespace"
assert_grep "same-name skills both recorded" '"provider": "local-pkg2"' "$STATE"
# Bare selectors are ambiguous when two providers ship the same name; the
# provider/skill selector remains deterministic.
assert_fails "ambiguous bare remove fails" "$ZYM" remove local-skill
assert_grep "ambiguity suggests provider/skill" "matches multiple providers" "$LOG"
assert_ok "remove one same-named skill by provider" "$ZYM" remove local-pkg2/local-skill
assert_skill_link "$HOME/.claude/skills/local-pkg/local-skill" "/skills/local-skill" "other provider survives removal"
ok "provider namespaces allow same-named skills without collision"

# ---------------------------------------------------------------------------
# remove
# ---------------------------------------------------------------------------
assert_ok "remove" "$ZYM" remove local-skill
assert_grep "remove reports the skill" "removed local-pkg/local-skill" "$LOG"
[ ! -e "$HOME/.claude/skills/local-pkg/local-skill" ] || fail "remove unlinks the skill" "link still present"
assert_absent "remove forgets the skill" "local-skill" "$STATE"
ok "remove unlinks the skill and drops it from state"

assert_fails "removing an unknown skill fails" "$ZYM" remove no-such-skill
assert_grep "unknown skill is explained" "is not provisioned" "$LOG"
assert_exit 2 "remove without an argument is a usage error" "$ZYM" remove
ok "removing a skill that is not provisioned fails"

# ---------------------------------------------------------------------------
# Machine-readable output
# ---------------------------------------------------------------------------
cd "$APP2"
assert_ok "sync --json" "$ZYM" sync --json
assert_json "sync --json is an object" "linked" "$LOG"
assert_ok "list --json" "$ZYM" list --json
assert_json "list --json is an object" "skills" "$LOG"
assert_grep "list --json carries provenance" '"source_kind"' "$LOG"
assert_ok "sources --json" "$ZYM" sources --json
assert_json "sources --json is an object" "sources" "$LOG"
cd "$NEUTRAL"
assert_ok "doctor --json" "$ZYM" doctor --json
assert_json "doctor --json is an object" "problems" "$LOG"

# ---------------------------------------------------------------------------
# Installation topologies.
#
# zymposium has to behave correctly in three distinct states, and the bug that
# matters most is one that only appears in one of them:
#
#   T1  zymposium NOT installed via zest, zest NOT present
#   T2  zymposium NOT installed via zest, zest IS present
#   T3  zymposium installed via zest,    zest IS present
#
# T1 and T2 share a feature set — project dependencies and `add`, with no tool
# skills at all — and differ only in whether a zest manifest exists that zymposium
# must not choke on. T3 is the only state where `zest tools` is a source and
# where zymposium's own skills come from the manifest rather than from walking
# up from the running binary.
# ---------------------------------------------------------------------------
# Resets state, config, home, the zest tree, and project-local links, so each
# topology starts from a machine with nothing provisioned. The ${var:?} guards
# make an unset variable an error rather than an `rm -rf /`.
topology() {
    rm -rf "${XDG_DATA_HOME:?}" "${XDG_CONFIG_HOME:?}" "${HOME:?}"
    mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME"
    ZEST_TREE="$XDG_DATA_HOME/zest"
    # Wiping the manifest means zymposium no longer owns the project-local
    # links the earlier sections created. Leaving them would be a *correct*
    # conflict on the next sync, so clear them along with everything else.
    for app in "$APP" "$APP2"; do
        for d in .claude .codex .agent; do
            rm -rf "${app:?}/${d}"
        done
    done
}

# The zest manifest, written by hand: this is exactly the shape `zest install`
# leaves behind, which is what makes T2 and T3 hermetically testable here.
# The real install path is covered separately by the install-via-zest CI job.
write_zest_state() { # <tool> <url> <version> <commit>
    mkdir -p "$ZEST_TREE/src/$1"
    cat >"$ZEST_TREE/state.json" <<EOF
{
  "version": 1,
  "tools": {
    "$1": {
      "source_url": "$2",
      "version": "$3",
      "commit": "$4",
      "installed_binary": "$ZEST_TREE/bin/$1",
      "installed_at": "2026-09-30T00:00:00Z"
    }
  }
}
EOF
}

TOP="$WORK/topology"
mkdir -p "$TOP"

# -- T1: no zest at all --------------------------------------------------
topology
[ -e "$ZEST_TREE" ] && fail "T1 starts without a zest tree" "found $ZEST_TREE"
"$ZYM" init >"$LOG" 2>&1 || fail "T1 init" "$(cat "$LOG")"
"$ZYM" sync --project "$APP" >"$LOG" 2>&1 || fail "T1 sync" "$(cat "$LOG")"
assert_grep "T1 discovers project deps" "dep-b-skill" "$STATE"
assert_grep "T1 provisions its own skills" "zymposium" "$STATE"
assert_skill_link "$HOME/.claude/skills/zymposium/zymposium" "/skills/zymposium" "T1 self skill"
# No zest means no zest skill: the skill ships in zest, not here.
[ ! -e "$HOME/.claude/skills/zest/zest" ] ||
    fail "T1 has no zest skill" "zest skill linked without zest"
ok "T1: the zest skill is absent when zest is not installed"
assert_ok "T1 doctor is clean" "$ZYM" doctor
ok "T1: works standalone with no zest, provisioning its own skills"

# -- T2: zest present, zymposium not installed via it --------------------
topology
write_zest_state other-tool "https://example.com/other-tool" "v2.0.0" "aaaa1111"
skill "$ZEST_TREE/src/other-tool/skills" other-skill "Skill from a zest tool"
"$ZYM" init >"$LOG" 2>&1 || fail "T2 init" "$(cat "$LOG")"
"$ZYM" sync --project "$APP" >"$LOG" 2>&1 || fail "T2 sync" "$(cat "$LOG")"
assert_grep "T2 still discovers project deps" "dep-b-skill" "$STATE"
assert_grep "T2 provisions its own skills" "zymposium" "$STATE"
# The tool exists in the manifest, so its skills are discoverable here too:
# T2 is "not installed via zest", not "zest is ignored".
assert_grep "T2 picks up the zest tool's skills" "other-skill" "$STATE"
assert_skill_link "$HOME/.claude/skills/other-tool/other-skill" "/skills/other-skill" "T2 tool skill"
assert_ok "T2 doctor is clean" "$ZYM" doctor
ok "T2: works standalone while a zest install is present"

# A zest manifest that is not valid JSON must degrade to a warning, never fail
# the run: zymposium is a guest in zest's directory.
topology
mkdir -p "$ZEST_TREE"
echo "{ not json" >"$ZEST_TREE/state.json"
# The warning goes to stderr, which a merged stdout+stderr capture can hide, so
# it is asserted against stderr alone.
assert_stderr_grep "T2 corrupt manifest warns" "ignoring unreadable zest state" \
    "$ZYM" sync --project "$APP"
"$ZYM" sync --project "$APP" >"$LOG" 2>&1 || fail "T2 corrupt manifest" "$(cat "$LOG")"
assert_grep "T2 corrupt manifest still syncs" "dep-b-skill" "$STATE"
ok "T2: a corrupt zest manifest warns and does not fail the run"

# -- T3: zymposium installed via zest -------------------------------------
topology
# Mirror the real install: zest clones the package into src/ and records it.
mkdir -p "$ZEST_TREE/src" "$ZEST_TREE/bin" "$ZEST_TREE/self/src"
cp -r "$REPO" "$ZEST_TREE/src/zymposium"
# zest keeps its own source tree at <zest root>/self/src; that is where
# zymposium looks for the skill zest ships about itself. Prefer the real one
# from a sibling checkout, and fall back to a fixture when zest is not there.
if [ -d "$REPO/../zest/skills/zest" ]; then
    cp -r "$REPO/../zest/skills" "$ZEST_TREE/self/src/skills"
else
    skill "$ZEST_TREE/self/src/skills" zest "Driving zest"
fi
cat >"$ZEST_TREE/self/src/build.zig.zon" <<'EOF'
.{
    .name = .zest,
    .version = "0.1.0",
    .fingerprint = 0x1111111111111111,
    .minimum_zig_version = "0.16.0",
    .dependencies = .{},
    .paths = .{ "build.zig.zon", "skills" },
}
EOF
gitfix "$ZEST_TREE/self/src"
rm -rf "$ZEST_TREE/src/zymposium/.git" "$ZEST_TREE/src/zymposium/.zig-cache" \
    "$ZEST_TREE/src/zymposium/zig-out"
cat >"$ZEST_TREE/state.json" <<EOF
{
  "version": 1,
  "tools": {
    "zymposium": {
      "source_url": "$(fileurl "$REPO")",
      "version": "v0.1.0",
      "commit": "bbbb2222",
      "installed_binary": "$ZEST_TREE/bin/zymposium",
      "installed_at": "2026-09-30T00:00:00Z"
    },
    "other-tool": {
      "source_url": "https://example.com/other-tool",
      "version": "v2.0.0",
      "commit": "aaaa1111",
      "installed_binary": "$ZEST_TREE/bin/other-tool",
      "installed_at": "2026-09-30T00:00:00Z"
    }
  }
}
EOF
skill "$ZEST_TREE/src/other-tool/skills" other-skill "Skill from a zest tool"

# The binary under test is the one zest would have installed, so self-discovery
# resolves through the zest clone rather than the development tree.
cp "$ZYM" "$ZEST_TREE/bin/zymposium.exe" 2>/dev/null || cp "$ZYM" "$ZEST_TREE/bin/zymposium"
if [ -f "$ZEST_TREE/bin/zymposium.exe" ]; then T3_ZYM="$ZEST_TREE/bin/zymposium.exe"; else T3_ZYM="$ZEST_TREE/bin/zymposium"; fi

"$T3_ZYM" init >"$LOG" 2>&1 || fail "T3 init" "$(cat "$LOG")"
"$T3_ZYM" sync --project "$APP" >"$LOG" 2>&1 || fail "T3 sync" "$(cat "$LOG")"

# The manifest's zymposium entry wins the provider name, so provenance is the
# richer zest_tool kind rather than the self-discovered package one.
assert_grep "T3 records zymposium as a zest tool" '"provider": "zymposium"' "$STATE"
assert_grep "T3 zymposium provenance is zest_tool" '"source_kind": "zest_tool"' "$STATE"
assert_grep "T3 still records the other tool" "other-skill" "$STATE"
assert_skill_link "$HOME/.claude/skills/other-tool/other-skill" "/skills/other-skill" "T3 tool skill"
assert_skill_link "$HOME/.claude/skills/zymposium/zymposium" "/skills/zymposium" "T3 self skill"
assert_skill_link "$HOME/.claude/skills/zest/zest" "/skills/zest" "T3 zest skill from zest's own source tree"
assert_ok "T3 doctor is clean" "$T3_ZYM" doctor
ok "T3: installed via zest, self-skills resolve through the zest clone"
"$T3_ZYM" sync --tool zest >"$LOG" 2>&1 || fail "T3 sync --tool zest" "$(cat "$LOG")"
assert_skill_link "$HOME/.claude/skills/zest/zest" "/skills/zest" "zest skill is separately namespaced"
assert_grep "T3 zest skills use the zest provider" '"provider": "zest"' "$STATE"
ok "zymposium can target zest's own skill source"

# A targeted re-sync — what zest runs after every install/update/remove — must
# touch only that provider and leave the others alone.
"$T3_ZYM" sync --tool other-tool >"$LOG" 2>&1 || fail "T3 sync --tool" "$(cat "$LOG")"
assert_grep "T3 --tool reports the untouched provider" "unchanged" "$LOG"
assert_skill_link "$HOME/.claude/skills/zymposium/zymposium" "/skills/zymposium" "T3 --tool keeps self skill"
ok "T3: a targeted sync leaves other providers intact"

# The transcript is echoed to the real stderr so a CI log shows every check,
# and the run ends with the summary line on that same stream.
cat "$TRANSCRIPT" >&3
printf 'PASS mock-e2e.sh (%d checks)\n' "$PASS" >&3
