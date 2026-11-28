#!/usr/bin/env bash
# noodle runners without GitHub: repo list, validation, off state, and start refusing without repos or a sign-in.
# Runs against a temporary HOME and NOODLE_HOME. No daemon, no VM, no network.
# Live test (needs a real repo and a GitHub sign-in): noodle runners add <owner/repo> [--macos]; noodle runners start;
# change runs-on to [self-hosted, noodle] (or [self-hosted, noodle-macos]); run the workflow; noodle runners status; noodle runners stop.
# Usage: NOODLE_BIN=.build/debug/noodle tests/runners.sh
set -euo pipefail

noodle=${NOODLE_BIN:?set NOODLE_BIN}
work=$(mktemp -d /tmp/noodle-runners.XXXXXX)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home NOODLE_HOME=$work/noodle NOODLE_NO_LAUNCHCTL=1 GIT_CONFIG_GLOBAL=$work/gitconfig GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
mkdir -p "$HOME"
# An empty helper entry clears every helper, including Apple's keychain one, so no real token is found.
printf '[credential]\n\thelper =\n' >"$work/gitconfig"
pass=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

"$noodle" runners list | grep -q "No repos" && ok "empty list" || fail "empty list"
"$noodle" runners add ../evil 2>/dev/null && fail "bad repo accepted" || ok "bad repo rejected"
refused=$("$noodle" runners add acme/app 2>&1 || true)
grep -q "full access to Noodle's Docker engine" <<<"$refused" && ! "$noodle" runners list | grep -q "acme/app" && ok "Linux refused without a private-repo check" || fail "linux refusal: $refused"
"$noodle" runners add acme/app --allow-public | grep -q "runs-on: \[self-hosted, noodle\]" && ok "add prints the one line" || fail "add"
refused=$("$noodle" runners add acme/mac --macos 2>&1 || true)
grep -q "allow-public" <<<"$refused" && ! "$noodle" runners list | grep -q "acme/mac" && ok "macOS refused without a private-repo check" || fail "macos refusal: $refused"
"$noodle" runners add acme/mac --macos --allow-public | grep -q "not a sandbox" && ok "macOS opt-in warns" || fail "macos warning"
list=$("$noodle" runners list)
grep -q "acme/app  linux  off" <<<"$list" && grep -q "acme/mac  linux+macos  off" <<<"$list" && ok "list shows kinds and state" || fail "list: $list"
git init -q "$work/repo" && git -C "$work/repo" remote add origin git@github.com:acme/here.git
(cd "$work/repo" && "$noodle" runners add --allow-public) | grep -q "Added acme/here" && ok "add with no repo uses the folder's remote" || fail "add from folder"
grep -q "no GitHub remote" <<<"$(cd "$work" && "$noodle" runners add 2>&1 || true)" && ok "add with no remote explains" || fail "add without remote"
"$noodle" runners status | grep -q "Runners off" && ok "status off" || fail "status"
started=$("$noodle" runners start 2>&1 || true)
grep -qi "no GitHub sign-in" <<<"$started" && ok "start needs a sign-in" || fail "start without sign-in: $started"
"$noodle" runners pause acme/app >/dev/null && "$noodle" runners list | grep -q "acme/app  linux  paused" && ok "pause" || fail "pause"
"$noodle" runners resume acme/app >/dev/null && "$noodle" runners list | grep -q "acme/app  linux  off" && ok "resume" || fail "resume"
"$noodle" runners pause acme/nope 2>/dev/null && fail "pause unknown repo" || ok "pause unknown repo refused"
grep -q '"engine" : false' <<<"$("$noodle" runners cache --json)" && "$noodle" runners cache | grep -q "Logs" && ok "cache report without the engine" || fail "cache"
"$noodle" runners cache clear acme/app 2>/dev/null && fail "cache clear without the engine" || ok "cache clear needs the engine"
"$noodle" runners remove acme/app >/dev/null && ! "$noodle" runners list | grep -q "acme/app" && ok "remove" || fail "remove"
"$noodle" runners stop | grep -q "Already off" && ok "stop when off" || fail "stop"
echo "runners.sh: $pass checks passed"
