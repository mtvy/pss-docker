#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

_invocation="${0##*/}"

# Parse arguments: -f <filter>  -a (all)  -m (memory)  -mi (memory + image size)
_filter=""
_all=false
_show_memory=false
_show_image=false
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
    -mi)
      _show_memory=true
      _show_image=true
      shift
      ;;
    -m)
      _show_memory=true
      shift
      ;;
    *)
      echo "${_invocation}: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

# Shared card format template (fast path)
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

# Fast path: no memory/image extras
if [[ "$_show_memory" == false && "$_show_image" == false ]]; then
  "${_docker_ps_cmd[@]}" --format "$_docker_ps_fmt"
  exit 0
fi

# Extended path: -m / -mi
_lookup_memory() {
  local _name="$1"
  local _line
  _line=$(echo "$_stats_data" | grep -F "${_name}|" | head -n1 || true)
  if [[ -z "$_line" ]]; then
    _line=$(echo "$_stats_data" | grep -F "/${_name}|" | head -n1 || true)
  fi
  if [[ -n "$_line" ]]; then
    echo "${_line#*|}"
  else
    echo "-"
  fi
}

_lookup_image_info() {
  local _container_id="$1"
  local _image_name="$2"
  local _image_sha _short_id _line

  _image_sha=$(docker inspect --format '{{.Image}}' "$_container_id" 2>/dev/null || true)
  if [[ -n "$_image_sha" ]]; then
    _short_id="${_image_sha#sha256:}"
    _short_id="${_short_id:0:12}"
    _line=$(echo "$_images_data" | grep -F "${_short_id}|" | head -n1 || true)
    if [[ -n "$_line" ]]; then
      echo "${_line#*|}"
      return
    fi
  fi

  # Fallback: match by repo:tag name from docker ps
  _line=$(echo "$_images_data" | grep -F "|${_image_name}|" | head -n1 || true)
  if [[ -n "$_line" ]]; then
    echo "${_line#*|}"
  else
    echo "${_image_name}|-"
  fi
}

_stats_data=""
if [[ "$_show_memory" == true ]]; then
  _stats_data=$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null || true)
fi

_images_data=""
if [[ "$_show_image" == true ]]; then
  _images_data=$(docker images --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}' 2>/dev/null || true)
fi

_ps_pipe_fmt='{{.Names}}	{{.Image}}	{{.Ports}}	{{.ID}}	{{.Command}}	{{.CreatedAt}}	{{.RunningFor}}	{{.State}}	{{.Status}}	{{.Size}}	{{.Networks}}'
_ps_output=$("${_docker_ps_cmd[@]}" --format "$_ps_pipe_fmt")

while IFS=$'\t' read -r _names _image _ports _id _command _created_at _running_for _state _status _size _networks; do
  [[ -z "$_names" ]] && continue

  printf '┌\033[93m%s\033[0m\n' "$_names"
  printf '│     [\033[96mImage\033[0m]      %s\n' "$_image"
  printf '│     [\033[96mPorts\033[0m]      %s\n' "$_ports"
  if [[ "$_show_memory" == true ]]; then
    _mem=$(_lookup_memory "$_names")
    printf '│     [\033[96mMemory\033[0m]      %s\n' "$_mem"
  fi
  printf '│     [\033[96mID\033[0m]         %s\n' "$_id"
  printf '│     [\033[96mCommand\033[0m]    %s\n' "$_command"
  printf '│     [\033[96mCreatedAt\033[0m]  %s\n' "$_created_at"
  printf '│     [\033[96mRunningFor\033[0m] %s\n' "$_running_for"
  printf '│     [\033[96mState\033[0m]      %s\n' "$_state"
  printf '│     [\033[96mStatus\033[0m]     %s\n' "$_status"
  printf '│     [\033[96mSize\033[0m]       %s\n' "$_size"
  printf '│     [\033[96mNames\033[0m]      %s\n' "$_names"
  printf '│     [\033[96mNetworks\033[0m]   %s\n' "$_networks"
  printf '└─────────────────\n'

  if [[ "$_show_image" == true ]]; then
    _img_info=$(_lookup_image_info "$_id" "$_image")
    _img_tag="${_img_info%%|*}"
    _img_size="${_img_info##*|}"
    printf '  ↳ [\033[96mImage\033[0m]  %s  (%s)\n' "$_img_tag" "$_img_size"
  fi
done <<< "$_ps_output"
