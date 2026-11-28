#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016,SC2086
# E2E checks: noodle logs and diagnostics. Sourced by tests/e2e.sh; do not run directly.

# `noodle logs` and `noodle diagnostics` read files only, so they run against a made-up home with known content.
diag_home() { # sets DH; fills daemon and vm logs with a secret, a home path and 300 numbered lines
  DH=$(mktemp -d /tmp/noodle-diag.XXXXXX)
  local i
  { for i in $(seq 1 300); do echo "line $i ok"; done
    echo "pull https://deploy:hunter2-pw@registry.example/v2/ failed"
    echo "Authorization: Bearer abcdef0123456789.secrettoken"
    echo "opened $HOME/private/project/file"
    echo "env AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  } >"$DH/noodled.log"
  echo "vm booted quietly" >"$DH/vm.log"
}

t_noodle_logs_tail_filter_and_redaction() {
  local cli=${NOODLE_CLI:-$ROOT/.build/release/noodle}; [ -x "$cli" ] || skip "noodle CLI not found (set NOODLE_CLI)"
  diag_home
  local nl="env NOODLE_HOME=$DH $cli" out
  out=$($nl logs engine -n 5); eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 5
  has "$out" "AWS_SECRET_ACCESS_KEY"; lacks "$out" "wJalrXUtnFEMI"
  out=$($nl logs engine -n 400)
  lacks "$out" "hunter2-pw"; lacks "$out" "secrettoken"; lacks "$out" "$HOME/private"
  has "$out" "line 1 ok"; has "$out" "[redacted]"
  has "$($nl logs engine -n 400 --raw)" "hunter2-pw"                      # --raw is the only way to see the original
  eq "$($nl logs engine --grep 'line 17' -n 100 | wc -l | tr -d ' ')" 11   # 17, 170 to 179
  eq "$($nl logs engine --grep nothing-like-this -n 100 | grep -c 'line')" 0
  has "$($nl logs engine -n 1)" "env"                                      # newest line last
  fails $nl logs bogus
  fails $nl logs engine -n notanumber
  has "$($nl logs 2>&1)" "==> engine"                                      # no component: every log, each with a header
  rm -rf "$DH"
}

# Component logs stay local. Containers use the real Docker CLI.
t_noodle_logs_container_passthrough() {
  local cli=${NOODLE_CLI:-$ROOT/.build/release/noodle}; [ -x "$cli" ] || skip "noodle CLI not found (set NOODLE_CLI)"
  local name=e2e-logs-pass marker=logs-marker-$$ response
  d rm -f "$name" >/dev/null 2>&1 || true
  d run --name "$name" "$IMG" sh -c "echo $marker; echo second-line" >/dev/null
  has "$(d logs "$name")" "$marker"
  if response=$("$cli" logs "$name" 2>&1); then
    d rm -f "$name" >/dev/null 2>&1
    echo 'container name accepted as a component log'; return 1
  fi
  has "$response" 'docker --context noodle logs CONTAINER'
  fails "$cli" logs --tail 1 "$name"
  fails "$cli" logs -f "$name"
  local comp; comp=$("$cli" logs engine -n 5 2>&1)
  [ -n "$comp" ] || { d rm -f "$name" >/dev/null 2>&1; return 1; }
  lacks "$comp" "$marker"
  d rm -f "$name" >/dev/null 2>&1
}

t_noodle_diagnostics_archive_is_scrubbed_and_private() {
  local cli=${NOODLE_CLI:-$ROOT/.build/release/noodle}; [ -x "$cli" ] || skip "noodle CLI not found (set NOODLE_CLI)"
  diag_home
  local out="$DH/out.tar.gz" x="$DH/x"
  has "$(env NOODLE_HOME=$DH "$cli" diagnostics -o "$out")" "Nothing was sent"
  eq "$(stat -f %Lp "$out")" 600
  mkdir "$x"; tar -xzf "$out" -C "$x"
  local top; top=$(ls "$x")
  eq "$top" out
  [ -f "$x/out/info.txt" ] && [ -f "$x/out/engine.log" ] || { echo "archive lacks info.txt or engine.log"; ls -R "$x"; return 1; }
  has "$(cat "$x/out/info.txt")" "noodle:"
  local all; all=$(cat "$x"/out/*)
  lacks "$all" "hunter2-pw"; lacks "$all" "secrettoken"; lacks "$all" "wJalrXUtnFEMI"; lacks "$all" "$HOME/private"
  has "$all" "[redacted]"
  [ "$(wc -l <"$x/out/engine.log")" -le 2001 ] || { echo "engine.log is not capped"; return 1; }
  fails env NOODLE_HOME=$DH "$cli" diagnostics --bogus
  rm -rf "$DH"
}

# Privacy regression block: real container output, state identity hints, crash reports and preview.
t_diagnostics_redact() (
  local cli=${NOODLE_CLI:-$ROOT/.build/release/noodle}
  [ -x "$cli" ] || { echo 'noodle CLI required for diagnostics-redact'; return 1; }
  local fixture="$WORK/diagnostics-redact" name=e2e-private-container
  local image=e2e-private-image:privacy project=e2e-private-project
  local token=ghp_PrivacyFixture0123456789abcdefghijkl
  mkdir -p "$fixture/crashes"
  trap 'd rm -f "$name" >/dev/null 2>&1 || true; d image rm "$image" >/dev/null 2>&1 || true; rm -rf "$fixture"' EXIT
  d tag "$IMG" "$image"
  d run --name "$name" --label "com.docker.compose.project=$project" -e "API_TOKEN=$token" "$image" sh -c 'printf "%s\n" "$API_TOKEN"; echo e2e-private-container e2e-private-image:privacy e2e-private-project private-host.example 203.0.113.42'
  d logs "$name" >"$fixture/noodled.log" 2>&1
  has "$(cat "$fixture/noodled.log")" "$token"
  has "$(cat "$fixture/noodled.log")" "$name"
  d inspect "$name" >"$fixture/state.json"
  cp "$fixture/noodled.log" "$fixture/crashes/noodled-private-host.ips"
  local preview archive="$fixture/bundle.tar.gz" all
  preview=$(env NOODLE_HOME="$fixture" timeout -k 5 30 "$cli" diagnostics --list)
  has "$preview" 'info.txt'; has "$preview" 'engine.log'; has "$preview" 'crash-1.ips'
  [ ! -e "$archive" ] || { echo 'preview created an archive'; return 1; }
  env NOODLE_HOME="$fixture" timeout -k 5 30 "$cli" diagnostics -o "$archive"
  mkdir "$fixture/extracted"
  tar -xzf "$archive" -C "$fixture/extracted"
  eq "$(stat -f %Lp "$archive")" 600
  local actual listed
  actual=$(find "$fixture/extracted/bundle" -type f -exec basename {} \; | sort)
  listed=$(printf '%s\n' "$preview" | sed 's/ <- .*//' | sort)
  eq "$actual" "$listed"
  all=$(cat "$fixture/extracted/bundle/"*)
  lacks "$all" "$token"; lacks "$all" "$name"; lacks "$all" "$image"; lacks "$all" "$project"
  lacks "$all" 'private-host.example'; lacks "$all" '203.0.113.42'
  has "$all" '[identity-'; has "$all" '[redacted]'
  cmp "$fixture/extracted/bundle/engine.log" "$fixture/extracted/bundle/crash-1.ips"
)
