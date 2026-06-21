#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

# Parse arguments: -f <filter>
_filter=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -f)
      if [[ $# -ge 2 ]]; then
        _filter="$2"
        shift 2
      else
        echo "d-ps: -f requires a value" >&2
        exit 1
      fi
      ;;
    *)
      echo "d-ps: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

# Determine invocation name (supports symlink: d-ps, dc-ps)
_invocation="${0##*/}"

# dc-ps → docker compose ps -a
if [[ "$_invocation" == "dc-ps" ]]; then
  _compose_format='{{.Name}}|{{.Image}}|{{.Command}}|{{.Status}}|{{.Size}}|{{.Service}}'
  if [[ -n "$_filter" ]]; then
    _compose_output=$(docker compose ps -a --filter "name=$_filter" --format "$_compose_format")
  else
    _compose_output=$(docker compose ps -a --format "$_compose_format")
  fi
  while IFS='|' read -r name image command status size service; do
    [[ -z "$name" ]] && continue
    printf '┌%s\n' "$(echo "$name" | sed 's/.*\///')"
    printf '│     [%s]      %s\n' "Image" "$image"
    printf '│     [%s]      %s\n' "Ports" ""
    printf '│     [%s]         -\n' "ID"
    printf '│     [%s]    %s\n' "Command" "$command"
    printf '│     [%s]  %s\n' "CreatedAt" ""
    printf '│     [%s] %s\n' "RunningFor" ""
    printf '│     [%s]      %s\n' "State" "$status"
    printf '│     [%s]     %s\n' "Status" "$status"
    printf '│     [%s]       %s\n' "Size" "$size"
    printf '│     [%s]      %s\n' "Names" "$name"
    printf '│     [%s]   %s\n' "Networks" "$service"
    printf '└─────────────────\n'
  done <<< "$_compose_output"
  exit 0
fi

# d-ps — docker ps with optional name filter
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

if [[ -n "$_filter" ]]; then
  docker ps --filter "name=$_filter" --format "$_docker_ps_fmt"
else
  docker ps --format "$_docker_ps_fmt"
fi
