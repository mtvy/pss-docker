#!/usr/bin/env bash
set -euo pipefail

_invocation="${0##*/}"

_show_help() {
  cat <<EOF
Usage: ${_invocation} [OPTIONS]

Colorized, card-style docker ps output — a readable alternative to the default flat table.

Options:
  -a              Show all containers (including stopped), like docker ps -a
  -f <name>       Filter by partial container name (substring match)
  -l              Compact card: name, ports (if any), and status only
  -ls             Show docker compose project directory below each card (if applicable)
  -d              Show docker compose depends_on graph after the cards (one per project)
  -m              Show container RAM usage below each card (docker stats)
  -mi             Show RAM usage and image name with disk size below each card
  -h, --help      Show this help message and exit

Examples:
  ${_invocation}                   List running containers
  ${_invocation} -a                List all containers
  ${_invocation} -f postgres       Containers whose name contains "postgres"
  ${_invocation} -l                Compact cards with name, ports, and status
  ${_invocation} -ls               Full cards with compose project directory
  ${_invocation} -a -d             All containers with compose dependency graphs
  ${_invocation} -a -d -f infogram Containers matching "infogram" with dependency graph
  ${_invocation} -l -m             Compact cards with memory usage below
  ${_invocation} -l -ls -mi        Compact cards with compose dir, memory, and image info
  ${_invocation} -a -f web -mi     All containers matching "web" with memory and image info

Color coding:
  Green   running / Up*
  Red     exited / Exited*
  Yellow  other states (paused, restarting, etc.)
  Cyan    field labels ([Image], [Ports], ...)

Requirements:
  Bash 3+, Docker CLI on PATH, terminal with ANSI color support.
EOF
}

# Parse arguments
_filter=""
_all=false
_lite=false
_show_compose_source=false
_show_deps_graph=false
_show_memory=false
_show_image=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      _show_help
      exit 0
      ;;
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
    -ls)
      _show_compose_source=true
      shift
      ;;
    -d)
      _show_deps_graph=true
      shift
      ;;
    -l)
      _lite=true
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

_docker_ps_lite_fmt='
┌'"$_state_fmt"'{{.Names}}{{"\033[0m"}}
{{if .Ports}}│     [{{"\033[36m"}}Ports{{"\033[0m"}}]      {{.Ports}}
{{end}}│     [{{"\033[36m"}}Status{{"\033[0m"}}]     '"$_state_fmt"'{{.Status}}{{"\033[0m"}}
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

_lookup_inspect_line() {
  local _id="$1"
  echo "$_inspect_data" | grep -F "${_id}|" | head -n1 || true
}

_lookup_compose_dir() {
  local _id="$1"
  local _line _dir
  _line=$(_lookup_inspect_line "$_id")
  if [[ -n "$_line" ]]; then
    _dir="${_line##*|}"
    if [[ -n "$_dir" ]]; then
      echo "$_dir"
    fi
  fi
}

_graph_register_project() {
  local _project="$1"
  if [[ -z "$_project" ]]; then
    return
  fi
  if echo "$_graph_projects" | grep -Fxq "$_project" 2>/dev/null; then
    return
  fi
  if [[ -z "$_graph_projects" ]]; then
    _graph_projects="$_project"
  else
    _graph_projects="${_graph_projects}"$'\n'"$_project"
  fi
}

_graph_register_node() {
  local _project="$1" _service="$2" _name="$3" _state="$4" _status="$5"
  local _line _prefix
  if [[ -z "$_project" || -z "$_service" ]]; then
    return
  fi
  _line="${_project}|${_service}|${_name}|${_state}|${_status}"
  _prefix="${_project}|${_service}|"
  if [[ -n "$_graph_nodes" ]]; then
    _graph_nodes=$(echo "$_graph_nodes" | grep -Fv "$_prefix" || true)
  fi
  if [[ -z "$_graph_nodes" ]]; then
    _graph_nodes="$_line"
  else
    _graph_nodes="${_graph_nodes}"$'\n'"$_line"
  fi
}

_graph_add_edge() {
  local _project="$1" _from="$2" _to="$3"
  local _line
  if [[ -z "$_project" || -z "$_from" || -z "$_to" ]]; then
    return
  fi
  _line="${_project}|${_from}|${_to}"
  if echo "$_graph_edges" | grep -Fxq "$_line" 2>/dev/null; then
    return
  fi
  if [[ -z "$_graph_edges" ]]; then
    _graph_edges="$_line"
  else
    _graph_edges="${_graph_edges}"$'\n'"$_line"
  fi
}

_graph_children() {
  local _project="$1" _from="$2" _p _f _t
  while IFS='|' read -r _p _f _t; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_f" == "$_from" ]]; then
      printf '%s\n' "$_t"
    fi
  done <<< "$_graph_edges"
}

_graph_is_dependent() {
  local _project="$1" _service="$2" _p _f _t
  while IFS='|' read -r _p _f _t; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_t" == "$_service" ]]; then
      return 0
    fi
  done <<< "$_graph_edges"
  return 1
}

_graph_project_has_edges() {
  local _project="$1" _p _f _t
  while IFS='|' read -r _p _f _t; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" ]]; then
      return 0
    fi
  done <<< "$_graph_edges"
  return 1
}

_graph_all_services() {
  local _project="$1" _p _s _f _t _n _st _stt _out
  _out=""
  while IFS='|' read -r _p _s _n _st _stt; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" ]]; then
      _out="${_out}${_s}"$'\n'
    fi
  done <<< "$_graph_nodes"
  while IFS='|' read -r _p _f _t; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" ]]; then
      _out="${_out}${_f}"$'\n'
      _out="${_out}${_t}"$'\n'
    fi
  done <<< "$_graph_edges"
  if [[ -z "$_out" ]]; then
    return 0
  fi
  printf '%s' "$_out" | grep -v '^$' 2>/dev/null | sort -u || true
}

_graph_find_node_line() {
  local _project="$1" _service="$2" _p _s _rest
  while IFS='|' read -r _p _s _rest; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_s" == "$_service" ]]; then
      printf '%s|%s|%s' "$_p" "$_s" "$_rest"
      return
    fi
  done <<< "$_graph_nodes"
}

_graph_print_node() {
  local _project="$1" _service="$2" _indent="$3"
  local _line _name _state _status _sc
  _line=$(_graph_find_node_line "$_project" "$_service")
  _name=""
  _state=""
  _status=""
  if [[ -n "$_line" ]]; then
    _name=$(printf '%s' "$_line" | cut -d'|' -f3)
    _state=$(printf '%s' "$_line" | cut -d'|' -f4)
    _status=$(printf '%s' "$_line" | cut -d'|' -f5)
  fi
  _sc=$(_state_color_code "$_state" "$_status")
  if [[ -n "$_name" ]]; then
    printf '%s%s%s%s  (%s)\n' "$_indent" "$_sc" "$_service" "$_C_RESET" "$_name"
  else
    printf '%s%s%s%s\n' "$_indent" "$_C_LABEL" "$_service" "$_C_RESET"
  fi
}

_graph_count_lines() {
  local _text="$1" _n=0 _line
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _n=$((_n + 1))
  done <<< "$_text"
  printf '%d' "$_n"
}

_graph_arrow_for_child() {
  local _total="$1" _index="$2"
  if [[ "$_total" -le 1 ]]; then
    printf '↓'
    return
  fi
  if [[ "$_total" -eq 2 ]]; then
    if [[ "$_index" -eq 0 ]]; then
      printf '↘'
    else
      printf '↙'
    fi
    return
  fi
  if [[ "$_index" -eq 0 ]]; then
    printf '↘'
  elif [[ "$_index" -eq $((_total - 1)) ]]; then
    printf '↙'
  else
    printf '↓'
  fi
}

_graph_print_chain() {
  local _project="$1" _service="$2" _indent="$3"
  local _child _children _first _child_total _child_index _arrow

  if echo "$_graph_visited" | grep -Fxq "$_service" 2>/dev/null; then
    printf '%s      %s↔ (cycle: %s)%s\n' "$_indent" "$_C_YELLOW" "$_service" "$_C_RESET"
    return
  fi
  if [[ -z "$_graph_visited" ]]; then
    _graph_visited="$_service"
  else
    _graph_visited="${_graph_visited}"$'\n'"$_service"
  fi

  _graph_print_node "$_project" "$_service" "$_indent"
  _children=$(_graph_children "$_project" "$_service")
  _child_total=$(_graph_count_lines "$_children")
  _child_index=0
  _first=true
  while IFS= read -r _child; do
    [[ -z "$_child" ]] && continue
    _arrow=$(_graph_arrow_for_child "$_child_total" "$_child_index")
    if [[ "$_first" == true ]]; then
      printf '%s      %s\n' "$_indent" "$_arrow"
      _first=false
    else
      printf '\n'
      printf '%s      %s\n' "$_indent" "$_arrow"
    fi
    _graph_print_chain "$_project" "$_child" "$_indent"
    _child_index=$((_child_index + 1))
  done <<< "$_children"
}

_print_dependency_graph() {
  local _project="$1"
  local _service _roots _root_count _printed_root

  _graph_visited=""
  _roots=""
  while IFS= read -r _service; do
    [[ -z "$_service" ]] && continue
    if ! _graph_is_dependent "$_project" "$_service"; then
      if [[ -z "$_roots" ]]; then
        _roots="$_service"
      else
        _roots="${_roots}"$'\n'"$_service"
      fi
    fi
  done <<< "$(_graph_all_services "$_project")"

  _root_count=0
  _printed_root=false
  while IFS= read -r _service; do
    [[ -z "$_service" ]] && continue
    _root_count=$((_root_count + 1))
  done <<< "$_roots"

  if [[ "$_root_count" -eq 0 ]]; then
    while IFS= read -r _service; do
      [[ -z "$_service" ]] && continue
      if [[ "$_printed_root" == true ]]; then
        printf '\n      ↕\n\n'
      fi
      _graph_visited=""
      _graph_print_chain "$_project" "$_service" "  "
      _printed_root=true
    done <<< "$(_graph_all_services "$_project")"
    return
  fi

  while IFS= read -r _service; do
    [[ -z "$_service" ]] && continue
    if [[ "$_printed_root" == true ]]; then
      printf '\n      ↕\n\n'
    fi
    _graph_visited=""
    _graph_print_chain "$_project" "$_service" "  "
    _printed_root=true
  done <<< "$_roots"
}

_print_all_dependency_graphs() {
  local _project _printed _header_printed

  [[ -z "$_graph_projects" ]] && return
  _header_printed=false
  _printed=false
  while IFS= read -r _project || [[ -n "$_project" ]]; do
    [[ -z "$_project" ]] && continue
    if ! _graph_project_has_edges "$_project"; then
      continue
    fi
    if [[ "$_header_printed" == false ]]; then
      printf '\n─────────────────\n'
      _header_printed=true
    fi
    if [[ "$_printed" == true ]]; then
      printf '\n'
    fi
    printf '%s── %s dependencies ──%s\n' "$_C_LABEL" "$_project" "$_C_RESET"
    _print_dependency_graph "$_project"
    _printed=true
  done <<< "$_graph_projects"
  if [[ "$_printed" == true ]]; then
    printf '\n'
  fi
}

_register_container_graph() {
  local _id="$1" _names="$2" _state="$3" _status="$4"
  local _meta _project _service _depends _dep _dep_svc

  _meta=$(_lookup_inspect_line "$_id")
  [[ -z "$_meta" ]] && return

  _project=$(printf '%s' "$_meta" | cut -d'|' -f2)
  _service=$(printf '%s' "$_meta" | cut -d'|' -f3)
  _depends=$(printf '%s' "$_meta" | cut -d'|' -f4)
  [[ -z "$_project" || -z "$_service" ]] && return

  _graph_register_project "$_project"
  _graph_register_node "$_project" "$_service" "$_names" "$_state" "$_status"

  if [[ -n "$_depends" ]]; then
    IFS=',' read -ra _dep_entries <<< "$_depends"
    for _dep in "${_dep_entries[@]}"; do
      _dep_svc="${_dep%%:*}"
      if [[ -n "$_dep_svc" ]]; then
        _graph_add_edge "$_project" "$_dep_svc" "$_service"
        _graph_register_node "$_project" "$_dep_svc" "" "" ""
      fi
    done
  fi
}

_print_extras() {
  local _names="$1" _id="$2" _image="$3"
  local _compose_dir _mem _img_info _img_tag _img_size

  if [[ "$_show_memory" == true ]]; then
    _mem=$(_lookup_memory "$_names")
    printf '  ↳ [%sMemory%s]  %s\n' "$_C_LABEL" "$_C_RESET" "$_mem"
  fi

  if [[ "$_show_image" == true ]]; then
    _img_info=$(_lookup_image_info "$_id" "$_image")
    _img_tag="${_img_info%%|*}"
    _img_size="${_img_info##*|}"
    printf '  ↳ [%sImage%s]  %s  (%s)\n' "$_C_LABEL" "$_C_RESET" "$_img_tag" "$_img_size"
  fi

  if [[ "$_show_compose_source" == true ]]; then
    _compose_dir=$(_lookup_compose_dir "$_id")
    if [[ -n "$_compose_dir" ]]; then
      printf '  ↳ [%sSource%s]  %s\n' "$_C_LABEL" "$_C_RESET" "$_compose_dir"
    fi
  fi

  if [[ "$_show_image" == true || "$_show_compose_source" == true ]]; then
    printf '\n'
  fi
}

_print_card_lite() {
  local _names="$1" _ports="$2" _state="$3" _status="$4" _id="$5" _image="$6"
  local _sc
  _sc=$(_state_color_code "$_state" "$_status")

  printf '┌%s%s%s\n' "$_sc" "$_names" "$_C_RESET"
  if [[ -n "$_ports" ]]; then
    printf '│     [%sPorts%s]      %s\n' "$_C_LABEL" "$_C_RESET" "$_ports"
  fi
  printf '│     [%sStatus%s]     %s%s%s\n' "$_C_LABEL" "$_C_RESET" "$_sc" "$_status" "$_C_RESET"
  printf '└─────────────────\n'

  _print_extras "$_names" "$_id" "$_image"
}

_print_card() {
  local _names="$1" _image="$2" _ports="$3" _id="$4" _command="$5"
  local _created_at="$6" _running_for="$7" _state="$8" _status="$9" _size="${10}" _networks="${11}"
  local _sc
  _sc=$(_state_color_code "$_state" "$_status")

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

  _print_extras "$_names" "$_id" "$_image"
}

# Build docker ps command with optional flags
_docker_ps_cmd=(docker ps)
if [[ "$_all" == true ]]; then
  _docker_ps_cmd+=(-a)
fi
if [[ -n "$_filter" ]]; then
  _docker_ps_cmd+=(--filter "name=$_filter")
fi

_need_extras=false
if [[ "$_show_memory" == true || "$_show_image" == true || "$_show_compose_source" == true ]]; then
  _need_extras=true
fi

# Fast path: full card, no extras, no dependency graph
if [[ "$_lite" == false && "$_need_extras" == false && "$_show_deps_graph" == false ]]; then
  "${_docker_ps_cmd[@]}" --format "$_docker_ps_fmt"
  exit 0
fi

# Fast path: lite card, no extras, no dependency graph
if [[ "$_lite" == true && "$_need_extras" == false && "$_show_deps_graph" == false ]]; then
  "${_docker_ps_cmd[@]}" --format "$_docker_ps_lite_fmt"
  exit 0
fi

# Extended path: extras, dependency graph, and/or lite with extras
_stats_data=""
if [[ "$_show_memory" == true ]]; then
  _stats_data=$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null || true)
fi

_images_data=""
if [[ "$_show_image" == true ]]; then
  _images_data=$(docker images --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}' 2>/dev/null || true)
fi

_inspect_data=""
_graph_projects=""
_graph_nodes=""
_graph_edges=""
if [[ "$_show_compose_source" == true || "$_show_deps_graph" == true ]]; then
  _container_ids=$("${_docker_ps_cmd[@]}" -q 2>/dev/null || true)
  if [[ -n "$_container_ids" ]]; then
    # shellcheck disable=SC2086
    _inspect_data=$(docker inspect --format '{{printf "%.12s" .ID}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.depends_on"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' $_container_ids 2>/dev/null || true)
  fi
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

  if [[ "$_show_deps_graph" == true ]]; then
    _register_container_graph "$_id" "$_names" "$_state" "$_status"
  fi

  if [[ "$_lite" == true ]]; then
    _print_card_lite "$_names" "$_ports" "$_state" "$_status" "$_id" "$_image"
  else
    _print_card "$_names" "$_image" "$_ports" "$_id" "$_command" "$_created_at" "$_running_for" "$_state" "$_status" "$_size" "$_networks"
  fi
done <<< "$_ps_output"

if [[ "$_show_deps_graph" == true ]]; then
  _print_all_dependency_graphs
fi
