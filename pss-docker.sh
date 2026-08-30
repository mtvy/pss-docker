#!/usr/bin/env bash
set -euo pipefail

_invocation="${0##*/}"

_show_help() {
  cat <<EOF
Usage: ${_invocation} [OPTIONS]

Colorized, card-style docker ps output — a readable alternative to the default flat table.
By default shows compact output grouped by Docker Compose project.

Options:
  -a              Show all containers (including stopped), like docker ps -a
  -f <name>       Filter by partial container name (substring match)
  -l              Compact output (default; accepted for compatibility)
  -v              Full cards (Image, Ports, ID, Command, …)
  -ls             Show docker compose project directory below each entry (if applicable)
  -d              Show docker compose depends_on trees after the list (one card per project)
  -m              Show container RAM usage below each entry (docker stats)
  -mi             Show RAM usage and image name with disk size below each entry
  -h, --help      Show this help message and exit

Examples:
  ${_invocation}                   Compact list, grouped by compose project
  ${_invocation} -a                All containers (including stopped)
  ${_invocation} -f postgres       Containers whose name contains "postgres"
  ${_invocation} -v                Full cards, still grouped by project
  ${_invocation} -ls               Compact list with compose project directory
  ${_invocation} -a -d             All containers with compose dependency graphs
  ${_invocation} -a -d -f infogram Containers matching "infogram" with dependency graph
  ${_invocation} -m                Compact list with memory usage below
  ${_invocation} -ls -mi           Compact list with compose dir, memory, and image info
  ${_invocation} -a -f web -mi     All containers matching "web" with memory and image info

Color coding:
  Green   running / Up*
  Red     exited / Exited*
  Yellow  other states (paused, restarting, etc.)
  Cyan    field labels ([Image], [Ports], ...) and project headers

Requirements:
  Bash 3+, Docker CLI on PATH, terminal with ANSI color support.
EOF
}

# Parse arguments
_filter=""
_all=false
_lite=true
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
      # Default mode; kept for compatibility
      _lite=true
      shift
      ;;
    -v)
      _lite=false
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

_lookup_compose_meta() {
  # Prints: project|service  (empty project if not compose)
  local _id="$1"
  local _line _project _service
  _line=$(_lookup_inspect_line "$_id")
  if [[ -z "$_line" ]]; then
    printf '|'
    return
  fi
  _project=$(printf '%s' "$_line" | cut -d'|' -f2)
  _service=$(printf '%s' "$_line" | cut -d'|' -f3)
  printf '%s|%s' "$_project" "$_service"
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

_register_display_project() {
  local _project="$1"
  if [[ -z "$_project" ]]; then
    return
  fi
  if echo "$_display_projects" | grep -Fxq "$_project" 2>/dev/null; then
    return
  fi
  if [[ -z "$_display_projects" ]]; then
    _display_projects="$_project"
  else
    _display_projects="${_display_projects}"$'\n'"$_project"
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
  local _line _prefix _existing
  if [[ -z "$_project" || -z "$_service" ]]; then
    return
  fi
  _prefix="${_project}|${_service}|"
  # Do not wipe a real container node with an empty depends_on placeholder
  if [[ -z "$_name" && -z "$_state" && -z "$_status" ]]; then
    _existing=$(echo "$_graph_nodes" | grep -F "$_prefix" | head -n1 || true)
    if [[ -n "$_existing" ]]; then
      return
    fi
  fi
  _line="${_project}|${_service}|${_name}|${_state}|${_status}"
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
  local _project="$1" _from="$2" _to="$3" _condition="${4:-}"
  local _line _key _p _f _t _c _kept=""
  if [[ -z "$_project" || -z "$_from" || -z "$_to" ]]; then
    return
  fi
  _key="${_project}|${_from}|${_to}|"
  _line="${_project}|${_from}|${_to}|${_condition}"
  # Replace existing same from→to edge (keep latest condition)
  while IFS='|' read -r _p _f _t _c; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_f" == "$_from" && "$_t" == "$_to" ]]; then
      continue
    fi
    if [[ -z "$_kept" ]]; then
      _kept="${_p}|${_f}|${_t}|${_c}"
    else
      _kept="${_kept}"$'\n'"${_p}|${_f}|${_t}|${_c}"
    fi
  done <<< "$_graph_edges"
  if [[ -z "$_kept" ]]; then
    _graph_edges="$_line"
  else
    _graph_edges="${_kept}"$'\n'"$_line"
  fi
}

_graph_children() {
  local _project="$1" _from="$2" _p _f _t _c
  while IFS='|' read -r _p _f _t _c; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_f" == "$_from" ]]; then
      printf '%s\n' "$_t"
    fi
  done <<< "$_graph_edges"
}

_graph_edge_condition() {
  local _project="$1" _from="$2" _to="$3" _p _f _t _c
  while IFS='|' read -r _p _f _t _c; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_f" == "$_from" && "$_t" == "$_to" ]]; then
      printf '%s' "$_c"
      return
    fi
  done <<< "$_graph_edges"
}

_graph_outgoing_condition() {
  # First non-default condition on any outgoing edge from this service
  local _project="$1" _service="$2" _p _f _t _c
  while IFS='|' read -r _p _f _t _c; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_f" == "$_service" ]]; then
      case "$_c" in
        ""|service_started) ;;
        *) printf '%s' "$_c"; return ;;
      esac
    fi
  done <<< "$_graph_edges"
}

_graph_is_dependent() {
  local _project="$1" _service="$2" _p _f _t _c
  while IFS='|' read -r _p _f _t _c; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" && "$_t" == "$_service" ]]; then
      return 0
    fi
  done <<< "$_graph_edges"
  return 1
}

_graph_project_has_edges() {
  local _project="$1" _p _f _t _c
  while IFS='|' read -r _p _f _t _c; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" ]]; then
      return 0
    fi
  done <<< "$_graph_edges"
  return 1
}

_graph_edge_services() {
  # Only services that participate in at least one depends_on edge
  local _project="$1" _p _f _t _c _out=""
  while IFS='|' read -r _p _f _t _c; do
    [[ -z "$_p" ]] && continue
    if [[ "$_p" == "$_project" ]]; then
      _out="${_out}${_f}"$'\n'"${_t}"$'\n'
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

_graph_condition_tag() {
  case "$1" in
    ""|service_started) printf '' ;;
    service_healthy) printf '[healthy]' ;;
    service_completed_successfully) printf '[completed]' ;;
    *) printf '[%s]' "$1" ;;
  esac
}

_graph_count_lines() {
  local _text="$1" _n=0 _line
  while IFS= read -r _line; do
    [[ -z "$_line" ]] && continue
    _n=$((_n + 1))
  done <<< "$_text"
  printf '%d' "$_n"
}

_graph_path_has() {
  [[ -n "$_graph_path" ]] && echo "$_graph_path" | grep -Fxq "$1" 2>/dev/null
}

_graph_path_push() {
  if [[ -z "$_graph_path" ]]; then
    _graph_path="$1"
  else
    _graph_path="${_graph_path}"$'\n'"$1"
  fi
}

_graph_path_pop() {
  if [[ "$_graph_path" != *$'\n'* ]]; then
    _graph_path=""
  else
    _graph_path="${_graph_path%$'\n'*}"
  fi
}

_graph_done_has() {
  [[ -n "$_graph_done" ]] && echo "$_graph_done" | grep -Fxq "$1" 2>/dev/null
}

_graph_done_add() {
  local _s="$1"
  if _graph_done_has "$_s"; then
    return
  fi
  if [[ -z "$_graph_done" ]]; then
    _graph_done="$_s"
  else
    _graph_done="${_graph_done}"$'\n'"$_s"
  fi
}

_graph_node_status_text() {
  # Prints: color_code|plain_text
  local _project="$1" _service="$2"
  local _line _name _state _status _cond _tag
  _line=$(_graph_find_node_line "$_project" "$_service")
  _name=""
  _state=""
  _status=""
  if [[ -n "$_line" ]]; then
    _name=$(printf '%s' "$_line" | cut -d'|' -f3)
    _state=$(printf '%s' "$_line" | cut -d'|' -f4)
    _status=$(printf '%s' "$_line" | cut -d'|' -f5)
  fi
  if [[ -n "$_status" ]]; then
    printf '%s|%s' "$(_state_color_code "$_state" "$_status")" "$_status"
    return
  fi
  _cond=$(_graph_outgoing_condition "$_project" "$_service")
  _tag=$(_graph_condition_tag "$_cond")
  if [[ -n "$_tag" ]]; then
    printf '%s|%s' "$_C_LABEL" "$_tag"
    return
  fi
  printf '%s|%s' "$_C_YELLOW" "not running"
}

_graph_print_tree_node() {
  local _project="$1" _service="$2" _indent="$3" _connector="$4" _svc_w="$5"
  local _parent="${6:-}"
  local _shared="${7:-false}"
  local _sc _stext _cond _tag
  _sc=$(_graph_node_status_text "$_project" "$_service")
  _stext="${_sc#*|}"
  _sc="${_sc%%|*}"
  if [[ -n "$_parent" ]]; then
    _cond=$(_graph_edge_condition "$_project" "$_parent" "$_service")
    _tag=$(_graph_condition_tag "$_cond")
    if [[ -n "$_tag" && "$_stext" != "$_tag" ]]; then
      _stext="${_stext}  ${_tag}"
    fi
  fi
  printf '│ %s%s%s%-*s%s  %s%s%s' \
    "$_indent" "$_connector" \
    "$_sc" "$_svc_w" "$_service" "$_C_RESET" \
    "$_sc" "$_stext" "$_C_RESET"
  if [[ "$_shared" == true ]]; then
    printf '  %s[shared]%s' "$_C_LABEL" "$_C_RESET"
  fi
  printf '\n'
}

_graph_cycle_members_from_path() {
  # Print members from back-edge target through end of path (newline-separated)
  local _target="$1" _s _started=false
  while IFS= read -r _s || [[ -n "${_s:-}" ]]; do
    [[ -z "${_s:-}" ]] && continue
    if [[ "$_s" == "$_target" ]]; then
      _started=true
    fi
    if [[ "$_started" == true ]]; then
      printf '%s\n' "$_s"
    fi
  done <<< "$_graph_path"
}

_graph_print_cycle_ring() {
  local _project="$1" _target="$2" _indent="$3" _connector="$4" _svc_w="$5"
  local _members _s _count=0 _chain="" _header _pad
  local _sc _stext _name_w=0 _status_w=0 _inner_w=0 _line_w _i _hlen _len
  local _all_done=true _a _b _fill

  _members=$(_graph_cycle_members_from_path "$_target")
  if [[ -z "$_members" ]]; then
    _graph_print_tree_node "$_project" "$_target" "$_indent" "$_connector" "$_svc_w" "" true
    return
  fi

  while IFS= read -r _s || [[ -n "${_s:-}" ]]; do
    [[ -z "${_s:-}" ]] && continue
    _count=$((_count + 1))
    if ! _graph_done_has "$_s"; then
      _all_done=false
    fi
    _len=$(_str_len "$_s")
    if [[ "$_len" -gt "$_name_w" ]]; then
      _name_w="$_len"
    fi
    _sc=$(_graph_node_status_text "$_project" "$_s")
    _stext="${_sc#*|}"
    _len=$(_str_len "$_stext")
    if [[ "$_len" -gt "$_status_w" ]]; then
      _status_w="$_len"
    fi
  done <<< "$_members"

  if [[ "$_all_done" == true ]]; then
    _graph_print_tree_node "$_project" "$_target" "$_indent" "$_connector" "$_svc_w" "" true
    return
  fi

  if [[ "$_name_w" -lt "$_svc_w" ]]; then
    _name_w="$_svc_w"
  fi

  if [[ "$_count" -eq 2 ]]; then
    _a=$(printf '%s\n' "$_members" | sed -n '1p')
    _b=$(printf '%s\n' "$_members" | sed -n '2p')
    _chain="${_a} ⇄ ${_b}"
    _header="╭─ ${_chain} ─╮"
  else
    _chain=""
    while IFS= read -r _s || [[ -n "${_s:-}" ]]; do
      [[ -z "${_s:-}" ]] && continue
      if [[ -z "$_chain" ]]; then
        _chain="$_s"
      else
        _chain="${_chain} → ${_s}"
      fi
    done <<< "$_members"
    _header="╭→ ${_chain} ╮"
  fi

  _hlen=$(_str_len "$_header")
  # content row: "|  name  status |" ≈ 1+2+name+2+status+1
  _line_w=$((4 + _name_w + 2 + _status_w + 1))
  _inner_w="$_hlen"
  if [[ "$_line_w" -gt "$_inner_w" ]]; then
    _inner_w="$_line_w"
  fi
  if [[ "$_inner_w" -lt 12 ]]; then
    _inner_w=12
  fi

  # Widen header with ─ before the closing corner if content is wider
  if [[ "$_inner_w" -gt "$_hlen" ]]; then
    _fill=$((_inner_w - _hlen))
    if [[ "$_count" -eq 2 ]]; then
      _header="╭─ ${_chain} "
      _i=0
      while [[ "$_i" -lt "$_fill" ]]; do
        _header="${_header}─"
        _i=$((_i + 1))
      done
      _header="${_header}╮"
    else
      _header="╭→ ${_chain} "
      _i=0
      while [[ "$_i" -lt "$_fill" ]]; do
        _header="${_header}─"
        _i=$((_i + 1))
      done
      _header="${_header}╮"
    fi
    _inner_w=$(_str_len "$_header")
  fi

  if [[ -n "$_connector" ]]; then
    _pad="${_indent}   "
  else
    _pad="$_indent"
  fi

  printf '│ %s%s%s%s%s\n' "$_indent" "$_connector" "$_C_YELLOW" "$_header" "$_C_RESET"

  while IFS= read -r _s || [[ -n "${_s:-}" ]]; do
    [[ -z "${_s:-}" ]] && continue
    _sc=$(_graph_node_status_text "$_project" "$_s")
    _stext="${_sc#*|}"
    _sc="${_sc%%|*}"
    printf '│ %s%s│  %s%-*s%s  %s%-*s%s %s│%s\n' \
      "$_pad" "$_C_YELLOW" \
      "$_sc" "$_name_w" "$_s" "$_C_RESET" \
      "$_sc" "$_status_w" "$_stext" "$_C_RESET" \
      "$_C_YELLOW" "$_C_RESET"
    _graph_done_add "$_s"
  done <<< "$_members"

  printf '│ %s%s╰' "$_pad" "$_C_YELLOW"
  _i=2
  while [[ "$_i" -lt "$_inner_w" ]]; do
    printf '─'
    _i=$((_i + 1))
  done
  printf '╯%s\n' "$_C_RESET"
}

_graph_print_tree() {
  # _indent: prefix before connector (e.g. "" / "│  " / "   ")
  # _connector: "" for root, "├─ " or "└─ " for children
  # _parent: parent service (empty for roots) — used for depends_on condition tags
  local _project="$1" _service="$2" _indent="$3" _connector="$4" _svc_w="$5"
  local _parent="${6:-}"
  local _child _children _child_total _child_index _is_last
  local _next_indent _next_conn

  # True cycle: back-edge to ancestor on current path
  if _graph_path_has "$_service"; then
    _graph_print_cycle_ring "$_project" "$_service" "$_indent" "$_connector" "$_svc_w"
    return
  fi

  # Shared: already fully rendered in another branch
  if _graph_done_has "$_service"; then
    _graph_print_tree_node "$_project" "$_service" "$_indent" "$_connector" "$_svc_w" "$_parent" true
    return
  fi

  _graph_path_push "$_service"
  _graph_print_tree_node "$_project" "$_service" "$_indent" "$_connector" "$_svc_w" "$_parent" false

  _children=$(_graph_children "$_project" "$_service")
  _child_total=$(_graph_count_lines "$_children")
  _child_index=0
  while IFS= read -r _child; do
    [[ -z "$_child" ]] && continue
    if [[ "$_child_index" -eq $((_child_total - 1)) ]]; then
      _is_last=true
      _next_conn="└─ "
    else
      _is_last=false
      _next_conn="├─ "
    fi
    if [[ -z "$_connector" ]]; then
      _next_indent=""
    elif [[ "$_connector" == "└─ " ]]; then
      _next_indent="${_indent}   "
    else
      _next_indent="${_indent}│  "
    fi
    _graph_print_tree "$_project" "$_child" "$_next_indent" "$_next_conn" "$_svc_w" "$_service"
    _child_index=$((_child_index + 1))
  done <<< "$_children"

  _graph_path_pop
  _graph_done_add "$_service"
}

_print_dependency_graph() {
  local _project="$1"
  local _service _roots _participants _svc_w=0 _len _rule_w _printed_root

  _participants=$(_graph_edge_services "$_project")
  [[ -z "$_participants" ]] && return

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
  done <<< "$_participants"

  # No roots (pure cycle component): start from every participant once
  if [[ -z "$_roots" ]]; then
    _roots="$_participants"
  fi

  _svc_w=0
  while IFS= read -r _service; do
    [[ -z "$_service" ]] && continue
    _len=$(_str_len "$_service")
    if [[ "$_len" -gt "$_svc_w" ]]; then
      _svc_w="$_len"
    fi
  done <<< "$_participants"
  if [[ "$_svc_w" -lt 8 ]]; then
    _svc_w=8
  fi

  printf '┌%s%s · depends_on%s\n' "$_C_LABEL" "$_project" "$_C_RESET"

  _printed_root=false
  _graph_path=""
  _graph_done=""
  while IFS= read -r _service; do
    [[ -z "$_service" ]] && continue
    if _graph_done_has "$_service"; then
      continue
    fi
    if [[ "$_printed_root" == true ]]; then
      printf '│\n'
    fi
    _graph_path=""
    _graph_print_tree "$_project" "$_service" "" "" "$_svc_w"
    _printed_root=true
  done <<< "$_roots"

  _rule_w=$((2 + 4 + _svc_w + 2 + 18))
  if [[ "$_rule_w" -lt 20 ]]; then
    _rule_w=20
  fi
  printf '└'
  _len=0
  while [[ "$_len" -lt "$_rule_w" ]]; do
    printf '─'
    _len=$((_len + 1))
  done
  printf '\n'
}

_print_all_dependency_graphs() {
  local _project

  [[ -z "$_graph_projects" ]] && return
  while IFS= read -r _project || [[ -n "${_project:-}" ]]; do
    [[ -z "${_project:-}" ]] && continue
    if ! _graph_project_has_edges "$_project"; then
      continue
    fi
    printf '\n'
    _print_dependency_graph "$_project"
  done <<< "$_graph_projects"
}

_register_container_graph() {
  local _id="$1" _names="$2" _state="$3" _status="$4"
  local _meta _project _service _depends _dep _dep_svc _dep_rest _dep_cond

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
      [[ -z "$_dep" ]] && continue
      _dep_svc="${_dep%%:*}"
      if [[ "$_dep" == *"|"* ]]; then
        # unexpected; treat whole as service
        _dep_svc="$_dep"
        _dep_cond=""
      elif [[ "$_dep" == *":"* ]]; then
        _dep_rest="${_dep#*:}"
        _dep_cond="${_dep_rest%%:*}"
      else
        _dep_cond=""
      fi
      if [[ -n "$_dep_svc" ]]; then
        _graph_add_edge "$_project" "$_dep_svc" "$_service" "$_dep_cond"
        _graph_register_node "$_project" "$_dep_svc" "" "" ""
      fi
    done
  fi
}

_print_extras() {
  local _names="$1" _id="$2" _image="$3"
  local _prefix="${4:-  }"
  local _compose_dir _mem _img_info _img_tag _img_size

  if [[ "$_show_memory" == true ]]; then
    _mem=$(_lookup_memory "$_names")
    printf '%s↳ [%sMemory%s]  %s\n' "$_prefix" "$_C_LABEL" "$_C_RESET" "$_mem"
  fi

  if [[ "$_show_image" == true ]]; then
    _img_info=$(_lookup_image_info "$_id" "$_image")
    _img_tag="${_img_info%%|*}"
    _img_size="${_img_info##*|}"
    printf '%s↳ [%sImage%s]  %s  (%s)\n' "$_prefix" "$_C_LABEL" "$_C_RESET" "$_img_tag" "$_img_size"
  fi

  if [[ "$_show_compose_source" == true ]]; then
    _compose_dir=$(_lookup_compose_dir "$_id")
    if [[ -n "$_compose_dir" ]]; then
      printf '%s↳ [%sSource%s]  %s\n' "$_prefix" "$_C_LABEL" "$_C_RESET" "$_compose_dir"
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

_str_len() {
  printf '%s' "$1" | wc -c | tr -d '[:space:]'
}

_simplify_ports() {
  local _ports="$1" _out
  if [[ -z "$_ports" ]]; then
    printf '-'
    return
  fi
  # Drop dual-stack IPv6 duplicates: "0.0.0.0:80->80/tcp, [::]:80->80/tcp" → "0.0.0.0:80->80/tcp"
  _out=$(printf '%s' "$_ports" | sed -E \
    -e 's/, *\[::\]:[0-9]+->[^,]+//g' \
    -e 's/^\[::\]:[0-9]+->[^,]+(, *)?//' \
    -e 's/^, *//' \
    -e 's/, *$//' \
    -e 's/  +/ /g')
  if [[ -z "$_out" ]]; then
    printf '%s' "$_ports"
  else
    printf '%s' "$_out"
  fi
}

_service_label() {
  local _service="$1" _names="$2"
  if [[ -n "$_service" ]]; then
    printf '%s' "$_service"
  else
    printf '%s' "$_names"
  fi
}

_print_project_header() {
  local _project="$1"
  printf '%s── %s ──%s\n' "$_C_LABEL" "$_project" "$_C_RESET"
}

_project_records() {
  local _project="$1" _rec _out=""
  while IFS= read -r _rec || [[ -n "${_rec:-}" ]]; do
    [[ -z "${_rec:-}" ]] && continue
    _parse_container_record "$_rec"
    if [[ "$_c_project" == "$_project" ]]; then
      if [[ -z "$_out" ]]; then
        _out="$_rec"
      else
        _out="${_out}"$'\n'"$_rec"
      fi
    fi
  done <<< "$_containers_data"
  printf '%s' "$_out"
}

_print_project_group_lite() {
  local _project="$1"
  local _recs _rec _svc _ports_disp _sc
  local _svc_w=0 _ports_w=0 _len _rule_w _i

  _recs=$(_project_records "$_project")
  [[ -z "$_recs" ]] && return

  # Measure columns for this project
  while IFS= read -r _rec || [[ -n "${_rec:-}" ]]; do
    [[ -z "${_rec:-}" ]] && continue
    _parse_container_record "$_rec"
    _svc=$(_service_label "$_c_service" "$_c_names")
    _ports_disp=$(_simplify_ports "$_c_ports")
    _len=$(_str_len "$_svc")
    if [[ "$_len" -gt "$_svc_w" ]]; then
      _svc_w="$_len"
    fi
    _len=$(_str_len "$_ports_disp")
    if [[ "$_len" -gt "$_ports_w" ]]; then
      _ports_w="$_len"
    fi
  done <<< "$_recs"

  # Minimum column widths for readability
  if [[ "$_svc_w" -lt 8 ]]; then
    _svc_w=8
  fi
  if [[ "$_ports_w" -lt 5 ]]; then
    _ports_w=5
  fi

  # Header width: "│ " + svc + "  " + ports + "  " + ~20 for status
  _rule_w=$((2 + _svc_w + 2 + _ports_w + 2 + 18))
  if [[ "$_rule_w" -lt 17 ]]; then
    _rule_w=17
  fi

  printf '┌%s%s%s\n' "$_C_LABEL" "$_project" "$_C_RESET"
  while IFS= read -r _rec || [[ -n "${_rec:-}" ]]; do
    [[ -z "${_rec:-}" ]] && continue
    _parse_container_record "$_rec"
    _svc=$(_service_label "$_c_service" "$_c_names")
    _ports_disp=$(_simplify_ports "$_c_ports")
    _sc=$(_state_color_code "$_c_state" "$_c_status")
    printf '│ %s%-*s%s  %-*s  %s%s%s\n' \
      "$_sc" "$_svc_w" "$_svc" "$_C_RESET" \
      "$_ports_w" "$_ports_disp" \
      "$_sc" "$_c_status" "$_C_RESET"
    _print_extras "$_c_names" "$_c_id" "$_c_image" "│   "
  done <<< "$_recs"
  printf '└'
  _i=0
  while [[ "$_i" -lt "$_rule_w" ]]; do
    printf '─'
    _i=$((_i + 1))
  done
  printf '\n'
}

_parse_container_record() {
  # Sets globals from a stored record (|||-separated).
  # Fields: project, service, names, image, ports, id, command, created_at,
  #         running_for, state, status, size, networks
  local _rec="$1"
  _c_project="${_rec%%$_ps_sep*}"
  _rest="${_rec#*$_ps_sep}"
  _c_service="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_names="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_image="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_ports="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_id="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_command="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_created_at="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_running_for="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_state="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_status="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_size="${_rest%%$_ps_sep*}"; _rest="${_rest#*$_ps_sep}"
  _c_networks="${_rest}"
}

_print_container_entry() {
  # Non-compose lite cards, or verbose full cards (with optional project header outside).
  if [[ "$_lite" == true ]]; then
    _print_card_lite "$_c_names" "$_c_ports" "$_c_state" "$_c_status" "$_c_id" "$_c_image"
  else
    _print_card "$_c_names" "$_c_image" "$_c_ports" "$_c_id" "$_c_command" \
      "$_c_created_at" "$_c_running_for" "$_c_state" "$_c_status" "$_c_size" "$_c_networks"
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

_inspect_data=""
_graph_projects=""
_graph_nodes=""
_graph_edges=""
_display_projects=""
_containers_data=""

_container_ids=$("${_docker_ps_cmd[@]}" -q 2>/dev/null || true)
if [[ -n "$_container_ids" ]]; then
  # shellcheck disable=SC2086
  _inspect_data=$(docker inspect --format '{{printf "%.12s" .ID}}|{{index .Config.Labels "com.docker.compose.project"}}|{{index .Config.Labels "com.docker.compose.service"}}|{{index .Config.Labels "com.docker.compose.depends_on"}}|{{index .Config.Labels "com.docker.compose.project.working_dir"}}' $_container_ids 2>/dev/null || true)
fi

_ps_sep='|||'
_ps_pipe_fmt='{{.Names}}|||{{.Image}}|||{{.Ports}}|||{{.ID}}|||{{.Command}}|||{{.CreatedAt}}|||{{.RunningFor}}|||{{.State}}|||{{.Status}}|||{{.Size}}|||{{.Networks}}'
_ps_output=$("${_docker_ps_cmd[@]}" --format "$_ps_pipe_fmt")

# Collect containers with compose metadata
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

  _meta=$(_lookup_compose_meta "$_id")
  _project="${_meta%%|*}"
  _service="${_meta#*|}"

  if [[ "$_show_deps_graph" == true ]]; then
    _register_container_graph "$_id" "$_names" "$_state" "$_status"
  fi

  if [[ -n "$_project" ]]; then
    _register_display_project "$_project"
  fi

  _rec="${_project}${_ps_sep}${_service}${_ps_sep}${_names}${_ps_sep}${_image}${_ps_sep}${_ports}${_ps_sep}${_id}${_ps_sep}${_command}${_ps_sep}${_created_at}${_ps_sep}${_running_for}${_ps_sep}${_state}${_ps_sep}${_status}${_ps_sep}${_size}${_ps_sep}${_networks}"
  if [[ -z "$_containers_data" ]]; then
    _containers_data="$_rec"
  else
    _containers_data="${_containers_data}"$'\n'"$_rec"
  fi
done <<< "$_ps_output"

# Render: compose projects first (grouped), then non-compose containers
_printed_any=false
while IFS= read -r _project || [[ -n "${_project:-}" ]]; do
  [[ -z "${_project:-}" ]] && continue
  if [[ "$_printed_any" == true ]]; then
    printf '\n'
  fi
  if [[ "$_lite" == true ]]; then
    _print_project_group_lite "$_project"
  else
    _print_project_header "$_project"
    while IFS= read -r _rec || [[ -n "${_rec:-}" ]]; do
      [[ -z "${_rec:-}" ]] && continue
      _parse_container_record "$_rec"
      if [[ "$_c_project" == "$_project" ]]; then
        _print_container_entry
      fi
    done <<< "$_containers_data"
  fi
  _printed_any=true
done <<< "$_display_projects"

_has_non_compose=false
while IFS= read -r _rec || [[ -n "${_rec:-}" ]]; do
  [[ -z "${_rec:-}" ]] && continue
  _parse_container_record "$_rec"
  if [[ -z "$_c_project" ]]; then
    _has_non_compose=true
    break
  fi
done <<< "$_containers_data"

if [[ "$_has_non_compose" == true ]]; then
  if [[ "$_printed_any" == true ]]; then
    printf '\n'
  fi
  while IFS= read -r _rec || [[ -n "${_rec:-}" ]]; do
    [[ -z "${_rec:-}" ]] && continue
    _parse_container_record "$_rec"
    if [[ -z "$_c_project" ]]; then
      _print_container_entry
    fi
  done <<< "$_containers_data"
fi

if [[ "$_show_deps_graph" == true ]]; then
  _print_all_dependency_graphs
fi

printf '\n'
