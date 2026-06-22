#!/usr/bin/env bash
set -euo pipefail

#region agent log
_dps_debug_log() {
  [[ "${DPS_DEBUG:-}" == 1 ]] || return 0
  local _log="${DPS_DEBUG_LOG:-/Users/mtvy/code/other/psss-docker/.cursor/debug-e302a5.log}"
  mkdir -p "$(dirname "$_log")" 2>/dev/null || true
  local _hyp="$1" _loc="$2" _msg="$3"
  shift 3
  local _data="$*"
  local _ts
  _ts=$(($(date +%s) * 1000))
  printf '{"sessionId":"e302a5","hypothesisId":"%s","location":"%s","message":"%s","data":{%s},"timestamp":%s}\n' \
    "$_hyp" "$_loc" "$_msg" "$_data" "$_ts" >> "$_log" 2>/dev/null || true
}

_dps_has_esc() {
  [[ "$1" == *$'\033'* ]] && echo true || echo false
}

_dps_esc_hex() {
  printf '%s' "$1" | head -c 80 | od -An -tx1 2>/dev/null | tr -d '\n ' | head -c 120 || echo "n/a"
}
#endregion

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

# ANSI colors — basic 8-color palette (36/32/31/33) for broad terminal support
_C_RESET=$'\033[0m'
_C_LABEL=$'\033[36m'
_C_GREEN=$'\033[32m'
_C_RED=$'\033[31m'
_C_YELLOW=$'\033[33m'

_state_color_code() {
  local _state _status _state_lc
  _state="$1"
  _status="$2"
  _state_lc=$(printf '%s' "$_state" | tr '[:upper:]' '[:lower:]')

  case "$_state_lc" in
    running) printf '%s' "$_C_GREEN"; return ;;
    exited)  printf '%s' "$_C_RED"; return ;;
  esac

  case "$_status" in
    Up*)     printf '%s' "$_C_GREEN"; return ;;
    Exited*) printf '%s' "$_C_RED"; return ;;
  esac

  printf '%s' "$_C_YELLOW"
}

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

#region agent log
_dps_debug_log "H2" "pss-docker.sh:startup" "env_and_tty" \
  "\"TERM\":\"${TERM:-}\",\"NO_COLOR\":\"${NO_COLOR:-}\",\"tty_stdout\":$([ -t 1 ] && echo true || echo false),\"show_memory\":${_show_memory},\"show_image\":${_show_image},\"all\":${_all}"
#endregion

# Shared card format (fast path: docker ps --format)
_state_fmt='{{if eq .State "running"}}{{"\033[32m"}}{{else if eq .State "exited"}}{{"\033[31m"}}{{else}}{{"\033[33m"}}{{end}}'
_docker_ps_fmt='
┌'"$_state_fmt"'{{.Names}}{{"\033[0m"}}
│     [{{"\033[36m"}}Image{{"\033[0m"}}]      {{.Image}}
│     [{{"\033[36m"}}Ports{{"\033[0m"}}]      {{.Ports}}
│     [{{"\033[36m"}}ID{{"\033[0m"}}]         {{.ID}}
│     [{{"\033[36m"}}Command{{"\033[0m"}}]    {{.Command}}
│     [{{"\033[36m"}}CreatedAt{{"\033[0m"}}]  {{.CreatedAt}}
│     [{{"\033[36m"}}RunningFor{{"\033[0m"}}] {{.RunningFor}}
│     [{{"\033[36m"}}State{{"\033[0m"}}]      '"$_state_fmt"'{{.State}}{{"\033[0m"}}
│     [{{"\033[36m"}}Status{{"\033[0m"}}]     '"$_state_fmt"'{{.Status}}{{"\033[0m"}}
│     [{{"\033[36m"}}Size{{"\033[0m"}}]       {{.Size}}
│     [{{"\033[36m"}}Names{{"\033[0m"}}]      {{.Names}}
│     [{{"\033[36m"}}Networks{{"\033[0m"}}]   {{.Networks}}
└─────────────────\n'

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
  _sc=$(_state_color_code "$_state" "$_status")

  #region agent log
  if [[ "${DPS_DEBUG:-}" == 1 ]]; then
    local _hdr
    _hdr=$(printf '┌%s%s%s\n' "$_sc" "$_names" "$_C_RESET")
    _dps_debug_log "H3" "pss-docker.sh:_print_card" "printf_header" \
      "\"runId\":\"post-fix\",\"color_scheme\":\"basic\",\"state\":\"${_state}\",\"status\":\"${_status}\",\"has_esc\":$(_dps_has_esc "$_hdr"),\"hex\":\"$(_dps_esc_hex "$_hdr")\""
  fi
  #endregion

  printf '┌%s%s%s\n' "$_sc" "$_names" "$_C_RESET"
  printf '│     [%sImage%s]      %s\n' "$_C_LABEL" "$_C_RESET" "$_image"
  printf '│     [%sPorts%s]      %s\n' "$_C_LABEL" "$_C_RESET" "$_ports"
  printf '│     [%sID%s]         %s\n' "$_C_LABEL" "$_C_RESET" "$_id"
  printf '│     [%sCommand%s]    %s\n' "$_C_LABEL" "$_C_RESET" "$_command"
  printf '│     [%sCreatedAt%s]  %s\n' "$_C_LABEL" "$_C_RESET" "$_created_at"
  printf '│     [%sRunningFor%s] %s\n' "$_C_LABEL" "$_C_RESET" "$_running_for"
  printf '│     [%sState%s]      %s%s%s\n' "$_C_LABEL" "$_C_RESET" "$_sc" "$_state" "$_C_RESET"
  printf '│     [%sStatus%s]     %s%s%s\n' "$_C_LABEL" "$_C_RESET" "$_sc" "$_status" "$_C_RESET"
  printf '│     [%sSize%s]       %s\n' "$_C_LABEL" "$_C_RESET" "$_size"
  printf '│     [%sNames%s]      %s\n' "$_C_LABEL" "$_C_RESET" "$_names"
  printf '│     [%sNetworks%s]   %s\n' "$_C_LABEL" "$_C_RESET" "$_networks"
  printf '└─────────────────\n'

  if [[ "$_show_memory" == true ]]; then
    local _mem
    _mem=$(_lookup_memory "$_names")
    printf '  ↳ [%sMemory%s]  %s\n' "$_C_LABEL" "$_C_RESET" "$_mem"
  fi

  if [[ "$_show_image" == true ]]; then
    local _img_info _img_tag _img_size
    _img_info=$(_lookup_image_info "$_id" "$_image")
    _img_tag="${_img_info%%|*}"
    _img_size="${_img_info##*|}"
    printf '  ↳ [%sImage%s]  %s  (%s)\n\n' "$_C_LABEL" "$_C_RESET" "$_img_tag" "$_img_size"
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

# Fast path: no memory/image extras
if [[ "$_show_memory" == false && "$_show_image" == false ]]; then
  if [[ "${DPS_DEBUG:-}" == 1 ]]; then
    local _out _sample
    _out=$("${_docker_ps_cmd[@]}" --format "$_docker_ps_fmt")
    _sample=$(printf '%s' "$_out" | head -n 1)
    #region agent log
    _dps_debug_log "H1" "pss-docker.sh:fast_path" "docker_template_output" \
      "\"runId\":\"post-fix\",\"color_scheme\":\"basic\",\"has_esc\":$(_dps_has_esc "$_sample"),\"hex\":\"$(_dps_esc_hex "$_sample")\",\"literal_backslash\":$( [[ "$_sample" == *'\\033'* ]] && echo true || echo false)"
    _dps_debug_log "H4" "pss-docker.sh:fast_path" "state_fmt_snippet" \
      "\"state_fmt\":\"$(printf '%s' "$_state_fmt" | tr '"' "'")\""
    #endregion
    printf '%s' "$_out"
  else
    "${_docker_ps_cmd[@]}" --format "$_docker_ps_fmt"
  fi
  exit 0
fi

#region agent log
_dps_debug_log "H5" "pss-docker.sh:extended_path" "branch" "\"path\":\"extended\""
#endregion

_stats_data=""
if [[ "$_show_memory" == true ]]; then
  _stats_data=$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null || true)
fi

_images_data=""
if [[ "$_show_image" == true ]]; then
  _images_data=$(docker images --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}' 2>/dev/null || true)
fi

_ps_sep='|||'
_ps_pipe_fmt='{{.Names}}|||{{.Image}}|||{{.Ports}}|||{{.ID}}|||{{.Command}}|||{{.CreatedAt}}|||{{.RunningFor}}|||{{.State}}|||{{.Status}}|||{{.Size}}|||{{.Networks}}'
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
