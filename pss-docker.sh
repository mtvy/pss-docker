#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

# Determine invocation name (supports symlink: d-ps, dc-ps)
_invocation="${0##*/}"

# Parse arguments: -f <filter>
_filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      if [[ $# -ge 2 ]]; then
        _filter="$2"
        shift 2
      else
        echo "${_invocation}: -f requires a value" >&2
        exit 1
      fi
      ;;
    *)
      echo "${_invocation}: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

# Shared card format template (used by both d-ps and dc-ps)
_docker_ps_fmt='
┌{{"\033[93m"}}{{.Names}}{{"\033[0m"}}
│     [{{"\033[96m"}}Image{{"\033[0m"}}]      {{.Image}}
│     [{{"\033[96m"}}Ports{{"\033[0m"}}]      {{.Ports}}
│     [{{"\033[96m"}}ID{{"\033[0m"}}]         {{.ID}}
│     [{{"\033[96m"}}Command{{"\033[0m"}}]    {{.Command}}
│     [{{"\033[96m"}}CreatedAt{{"\033[0m"}}]  {{.CreatedAt}}
│     [{{"\033[96m"}}RunningFor{{"\033[0m"}}] {{.RunningFor}}
│     [{{"\033[96m"}}State{{"\033[0m"}}]      {{.State}}
│     [{{"\033[96m"}}Status{{"\033[0m"}}]     {{.Status}}
│     [{{"\033[96m"}}Size{{"\033[0m"}}]       {{.Size}}
│     [{{"\033[96m"}}Names{{"\033[0m"}}]      {{.Names}}
│     [{{"\033[96m"}}Networks{{"\033[0m"}}]   {{.Networks}}
└─────────────────\n'

# dc-ps → docker compose ps -a
if [[ "$_invocation" == "dc-ps" ]]; then
  _compose_fmt=$(echo "$_docker_ps_fmt" | sed 's/{{\.Names}}/{{.Name}}/g')
  if [[ -n "$_filter" ]]; then
    docker compose ps -a --format "$_compose_fmt" | grep -i "$_filter" || true
  else
    docker compose ps -a --format "$_compose_fmt"
  fi
  exit 0
fi

# d-ps — docker ps with optional name filter
if [[ -n "$_filter" ]]; then
  docker ps --filter "name=$_filter" --format "$_docker_ps_fmt"
else
  docker ps --format "$_docker_ps_fmt"
fi
