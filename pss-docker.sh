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

_state_color() {
  case "$1" in
    running) printf '%s' $'\033[92m' ;;
    exited)  printf '%s' $'\033[91m' ;;
    *)       printf '%s' $'\033[93m' ;;
  esac
}

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

  _line=$(echo "$_images_data" | grep -F "|${_image_name}|" | head -n1 || true)
  if [[ -n "$_line" ]]; then
    echo "${_line#*|}"
  else
    echo "${_image_name}|-"
  fi
}

_print_card() {
  local _names="$1" _image="$2" _ports="$3" _id="$4" _command="$5"
  local _created_at="$6" _running_for="$7" _state="$8" _status="$9" _size="${10}" _networks="${11}"
  local _sc
  _sc=$(_state_color "$_state")

  printf '┌%b%s\033[0m\n' "$_sc" "$_names"
  printf '│     [\033[96mImage\033[0m]      %s\n' "$_image"
  printf '│     [\033[96mPorts\033[0m]      %s\n' "$_ports"
  printf '│     [\033[96mID\033[0m]         %s\n' "$_id"
  printf '│     [\033[96mCommand\033[0m]    %s\n' "$_command"
  printf '│     [\033[96mCreatedAt\033[0m]  %s\n' "$_created_at"
  printf '│     [\033[96mRunningFor\033[0m] %s\n' "$_running_for"
  printf '│     [\033[96mState\033[0m]      %b%s\033[0m\n' "$_sc" "$_state"
  printf '│     [\033[96mStatus\033[0m]     %b%s\033[0m\n' "$_sc" "$_status"
  printf '│     [\033[96mSize\033[0m]       %s\n' "$_size"
  printf '│     [\033[96mNames\033[0m]      %s\n' "$_names"
  printf '│     [\033[96mNetworks\033[0m]   %s\n' "$_networks"
  printf '└─────────────────\n'

  if [[ "$_show_memory" == true ]]; then
    local _mem
    _mem=$(_lookup_memory "$_names")
    printf '  ↳ [\033[96mMemory\033[0m]  %s\n' "$_mem"
  fi

  if [[ "$_show_image" == true ]]; then
    local _img_info _img_tag _img_size
    _img_info=$(_lookup_image_info "$_id" "$_image")
    _img_tag="${_img_info%%|*}"
    _img_size="${_img_info##*|}"
    printf '  ↳ [\033[96mImage\033[0m]  %s  (%s)\n\n' "$_img_tag" "$_img_size"
  fi
}

# Build docker ps command with optional flags
_docker_ps_cmd=(docker ps)
if [[ "$_all" == true ]]; then
  _docker_ps_cmd+=(-a)
fi
if [[ -n "$_filter" ]]; then
  _docker_ps_cmd+=(--filter "name=$_filter")
fi

_stats_data=""
if [[ "$_show_memory" == true ]]; then
  _stats_data=$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null || true)
fi

_images_data=""
if [[ "$_show_image" == true ]]; then
  _images_data=$(docker images --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}' 2>/dev/null || true)
fi

_ps_sep=$'\x1f'
_ps_pipe_fmt='{{.Names}}{{"\x1f"}}{{.Image}}{{"\x1f"}}{{.Ports}}{{"\x1f"}}{{.ID}}{{"\x1f"}}{{.Command}}{{"\x1f"}}{{.CreatedAt}}{{"\x1f"}}{{.RunningFor}}{{"\x1f"}}{{.State}}{{"\x1f"}}{{.Status}}{{"\x1f"}}{{.Size}}{{"\x1f"}}{{.Networks}}'
_ps_output=$("${_docker_ps_cmd[@]}" --format "$_ps_pipe_fmt")

while IFS= read -r _line; do
  [[ -z "$_line" ]] && continue
  _names="${_line%%$_ps_sep*}"
  _rest="${_line#*$_ps_sep}"
  _image="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _ports="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _id="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _command="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _created_at="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _running_for="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _state="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _status="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _size="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _networks="${_rest}"
  [[ -z "$_names" ]] && continue
  _print_card "$_names" "$_image" "$_ports" "$_id" "$_command" "$_created_at" "$_running_for" "$_state" "$_status" "$_size" "$_networks"
done <<< "$_ps_output"
