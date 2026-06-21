#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is not installed or not on PATH" >&2
  exit 1
fi

_invocation="${0##*/}"

# Parse arguments: -f <filter>  -a (all)  -m (memory)  -mi (memory+image)
_filter=""
_all=false
_memory=false
_image_size=false
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
    -a|-m)
      _all=true
      if [[ "$1" == "-m" ]]; then _memory=true; fi
      shift
      ;;
    -mi)
      _all=true; _memory=true; _image_size=true
      shift
      ;;
    *)
      echo "${_invocation}: unknown argument '$1'" >&2
      exit 1
      ;;
  esac
done

# Memory lookup: container_name -> mem_usage (e.g. "1.2MB / 1.29GB")
declare -A _mem_map
if [[ "$_memory" == true ]]; then
  while IFS='|' read -r name mem; do
    [[ -n "$name" ]] && _mem_map["$name"]="$mem"
  done < <(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null || true)
fi

# Image size lookup: image_name -> size_bytes
declare -A _img_map
if [[ "$_image_size" == true ]]; then
  # Collect unique images from running containers
  declare -A _seen_images
  _ps_pipe_fmt='{{.Names}}|{{.Image}}|{{.ID}}|{{.Ports}}|{{.Command}}|{{.CreatedAt}}|{{.RunningFor}}|{{.State}}|{{.Status}}|{{.Size}}|{{.Networks}}'
  _all_args=()
  [[ "$_all" == true ]] && _all_args+=(-a)
  [[ -n "$_filter" ]] && _all_args+=(--filter "name=$_filter")
  while IFS='|' read -r name image rest; do
    if [[ -n "$name" && -z "${_seen_images[$image]:-}" ]]; then
      _seen_images["$image"]=1
      _img_size=$(docker inspect "$image" --format '{{.Size}}' 2>/dev/null || echo "0")
      # Convert bytes to human readable
      if (( _img_size >= 1073741824 )); then
        _img_human="$(( _img_size / 1073741824 ))GB"
      elif (( _img_size >= 1048576 )); then
        _img_human="$(( _img_size / 1048576 ))MB"
      elif (( _img_size >= 1024 )); then
        _img_human="$(( _img_size / 1024 ))KB"
      else
        _img_human="${_img_size}B"
      fi
      _img_map["$image"]="$_img_human"
    fi
  done < <(docker ps "${_all_args[@]}" --format "$_ps_pipe_fmt" 2>/dev/null || true)
fi

# Print total unique image size if -mi
_img_total=""
if [[ "$_image_size" == true && ${#_img_map[@]} -gt 0 ]]; then
  _img_total=$(printf "[ImageTotal] "
  _first=true
  for img in "${!_img_map[@]}"; do
    if [[ "$_first" == true ]]; then
      printf "%s(%s)" "$img" "${_img_map[$img]}"
      _first=false
    else
      printf ", %s(%s)" "$img" "${_img_map[$img]}"
    fi
  done
  _img_total=$(printf '%s' "${_img_total}")
fi

# Build cards manually
_ps_pipe_fmt='{{.Names}}|{{.Image}}|{{.ID}}|{{.Ports}}|{{.Command}}|{{.CreatedAt}}|{{.RunningFor}}|{{.State}}|{{.Status}}|{{.Size}}|{{.Networks}}'
_docker_ps_cmd=(docker ps)
if [[ "$_all" == true ]]; then
  _docker_ps_cmd+=(-a)
fi
if [[ -n "$_filter" ]]; then
  _docker_ps_cmd+=(--filter "name=$_filter")
fi

_docker_ps_cmd+=(--format "$_ps_pipe_fmt")

while IFS='|' read -r name image id ports command created_at running_for state status size networks; do
  [[ -z "$name" ]] && continue
  printf '┌\033[93m%s\033[0m\n' "$name"
  printf '│     [\033[96mImage\033[0m]      %s\n' "$image"
  if [[ "$_memory" == true ]]; then
    printf '│     [\033[96mMemory\033[0m]    %s\n' "${_mem_map[$name]:--}"
  fi
  printf '│     [\033[96mPorts\033[0m]      %s\n' "$ports"
  printf '│     [\033[96mID\033[0m]         %s\n' "$id"
  printf '│     [\033[96mCommand\033[0m]    %s\n' "$command"
  printf '│     [\033[96mCreatedAt\033[0m]  %s\n' "$created_at"
  printf '│     [\033[96mRunningFor\033[0m] %s\n' "$running_for"
  printf '│     [\033[96mState\033[0m]      %s\n' "$state"
  printf '│     [\033[96mStatus\033[0m]     %s\n' "$status"
  printf '│     [\033[96mSize\033[0m]       %s\n' "$size"
  printf '│     [\033[96mNames\033[0m]      %s\n' "$name"
  printf '│     [\033[96mNetworks\033[0m]   %s\n' "$networks"
  if [[ "$_image_size" == true && -n "$_img_total" ]]; then
    printf '│                               %s\n' "$_img_total"
  fi
  printf '└─────────────────\n'
done < <("${_docker_ps_cmd[@]}" 2>/dev/null || true)
