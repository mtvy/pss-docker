#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

_invocation="${0##*/}"

# Parse arguments: -f <filter>  -a (all containers)
_filter=""
_all=false
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
    -a)
      _all=true
      shift
      ;;
    *)
      echo "${_invocation}: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

# Shared card format template
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

# Build docker ps command with optional flags
_docker_ps_cmd=(docker ps)
if [[ "$_all" == true ]]; then
  _docker_ps_cmd+=(-a)
fi
if [[ -n "$_filter" ]]; then
  _docker_ps_cmd+=(--filter "name=$_filter")
fi

"${_docker_ps_cmd[@]}" --format "$_docker_ps_fmt"
