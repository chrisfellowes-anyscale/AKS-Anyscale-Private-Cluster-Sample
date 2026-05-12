#!/usr/bin/env bash

format_timeout_command_display() {
  local result_var="$1"
  shift

  local display=""
  printf -v display '%q ' "$@"
  printf -v "${result_var}" '%s' "${display% }"
}

run_with_timeout_gnu() {
  local timeout_binary="$1"
  local timeout_seconds="$2"
  shift 2

  local grace_seconds="${RUN_WITH_TIMEOUT_KILL_AFTER_SECONDS:-5}"
  "${timeout_binary}" --foreground --kill-after="${grace_seconds}s" "${timeout_seconds}" "$@"
}

run_with_timeout_perl() {
  local timeout_seconds="$1"
  shift

  perl -e '
use strict;
use warnings;
use POSIX qw(setsid);

my $timeout = shift @ARGV;
my $pid = fork();
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
  setsid() or die "setsid failed: $!";
  exec @ARGV or do { warn "exec failed: $!"; exit 127; };
}

my $grace = $ENV{RUN_WITH_TIMEOUT_KILL_AFTER_SECONDS};
$grace = 5 if !defined $grace || $grace eq q{};

local $SIG{ALRM} = sub {
  kill "TERM", -$pid;
  sleep $grace;
  kill "KILL", -$pid;
  waitpid($pid, 0);
  exit 124;
};

alarm($timeout);
waitpid($pid, 0);
alarm(0);

if ($? == -1) {
  exit 127;
}

if ($? & 127) {
  exit 128 + ($? & 127);
}

exit($? >> 8);
' "${timeout_seconds}" "$@"
}

run_with_timeout_bash_watchdog() {
  local timeout_seconds="$1"
  shift

  local grace_seconds="${RUN_WITH_TIMEOUT_KILL_AFTER_SECONDS:-5}"
  local -a command=("$@")
  local command_pid watchdog_pid exit_code

  "${command[@]}" &
  command_pid=$!

  (
    sleep "${timeout_seconds}"
    if kill -0 "${command_pid}" 2>/dev/null; then
      kill -TERM "${command_pid}" 2>/dev/null || true
      sleep "${grace_seconds}"
      kill -KILL "${command_pid}" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  wait "${command_pid}"
  exit_code=$?
  kill "${watchdog_pid}" 2>/dev/null || true
  wait "${watchdog_pid}" 2>/dev/null || true

  if [[ "${exit_code}" -eq 143 || "${exit_code}" -eq 137 ]]; then
    return 124
  fi

  return "${exit_code}"
}

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  local exit_code=0 command_display timeout_binary=""

  if [[ "$#" -eq 0 ]]; then
    printf '[error] run_with_timeout requires a command\n' >&2
    return 2
  fi

  if [[ -z "${timeout_seconds}" || "${timeout_seconds}" == "0" ]]; then
    "$@"
    return $?
  fi

  if timeout_binary="$(command -v timeout 2>/dev/null)" && [[ -n "${timeout_binary}" ]]; then
    run_with_timeout_gnu "${timeout_binary}" "${timeout_seconds}" "$@"
    exit_code=$?
  elif timeout_binary="$(command -v gtimeout 2>/dev/null)" && [[ -n "${timeout_binary}" ]]; then
    run_with_timeout_gnu "${timeout_binary}" "${timeout_seconds}" "$@"
    exit_code=$?
  elif command -v perl >/dev/null 2>&1; then
    run_with_timeout_perl "${timeout_seconds}" "$@"
    exit_code=$?
  else
    run_with_timeout_bash_watchdog "${timeout_seconds}" "$@"
    exit_code=$?
  fi

  if [[ "${exit_code}" -eq 124 ]]; then
    format_timeout_command_display command_display "$@"
    printf '[error] Timed out after %ss: %s\n' "${timeout_seconds}" "${command_display}" >&2
  fi

  return "${exit_code}"
}