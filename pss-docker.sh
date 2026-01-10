#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

docker ps --format '
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
