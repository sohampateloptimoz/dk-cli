#!/usr/bin/env zsh

set -euo pipefail

########################################
# VERSION
########################################

readonly VERSION="2.0.0"

########################################
# EXIT CODES
########################################

readonly EXIT_OK=0
readonly EXIT_GENERAL=1
readonly EXIT_USAGE=2
readonly EXIT_NOT_FOUND=3
readonly EXIT_DEPENDENCY=4

########################################
# CONFIGURATION
########################################

readonly CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dk"
readonly CONFIG_FILE="$CONFIG_DIR/projects.conf"

# PROJECTS[name] = /path/to/project
typeset -A PROJECTS

# PROJECT_ENVS[name:envname] = compose-file-path (relative to project dir)
typeset -A PROJECT_ENVS

# PROJECT_DEFAULT_ENV[name] = envname
typeset -A PROJECT_DEFAULT_ENV

########################################
# GLOBAL FLAGS
########################################

FORCE=false
PURGE=false
BUILD=false
QUIET=false
TAIL=""
CLEAN_DOWN=false
CLEAN_ARTIFACTS_ONLY=false
CLEAN_ALL=false
ENV_FLAG=""
CLEANED_ITEMS=0
CLEANED_NAMES=()

########################################
# COLOR SUPPORT
########################################

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_CYAN=$'\033[0;36m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_WHITE=$'\033[1;37m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_BOLD=""
  C_DIM=""
  C_WHITE=""
fi

########################################
# SIGNAL TRAP
########################################

trap 'echo "\n${C_YELLOW}Interrupted.${C_RESET}"; exit 130' INT TERM

########################################
# UTILITIES
########################################

log() {
  [[ "$QUIET" == true ]] && return
  echo "${C_GREEN}➜${C_RESET} $1"
}

warn() {
  [[ "$QUIET" == true ]] && return
  echo "${C_YELLOW}⚠${C_RESET} $1"
}

error() {
  echo "${C_RED}✖${C_RESET} $1" >&2
  exit "${2:-$EXIT_GENERAL}"
}

confirm() {
  if [[ "$FORCE" == true ]]; then
    return 0
  fi
  echo ""
  read "?${C_YELLOW}⚠${C_RESET} $1 (y/N): " ans
  if [[ "$ans" != "y" && "$ans" != "Y" ]]; then
    echo "Aborted."
    exit $EXIT_OK
  fi
}

# Ask a question and return the answer (does NOT exit on 'no')
ask() {
  read "?$1" ans
  echo "$ans"
}

########################################
# CONFIG FILE LOADER
########################################

# Config format:
#   project_name=/path/to/project
#   project_name.env.default=docker-compose.yml
#   project_name.env.dev=docker-compose.dev.yml
#   project_name.env.prod=docker/compose.prod.yml

load_config() {

  # Default projects (used when no config file exists)
  PROJECTS=(
    backend "$HOME/workspace/backend"
    analytics "$HOME/workspace/analytics"
    immunization "$HOME/workspace/immunization"
  )

  # Override with config file if it exists
  if [[ -f "$CONFIG_FILE" ]]; then

    PROJECTS=()
    PROJECT_ENVS=()
    PROJECT_DEFAULT_ENV=()

    local project_name env_name env_key

    while IFS='=' read -r key value || [[ -n "$key" ]]; do

      # Skip empty lines and comments
      [[ -z "$key" || "$key" == \#* ]] && continue

      # Trim whitespace
      key="${key## }"; key="${key%% }"
      value="${value## }"; value="${value%% }"

      # Expand ~ and $HOME
      value="${value/#\~/$HOME}"

      [[ -z "$key" || -z "$value" ]] && continue

      # Check if this is an environment entry: name.env.envname=file
      if [[ "$key" == *.env.* ]]; then
        project_name="${key%%.env.*}"
        env_name="${key##*.env.}"

        # __default__ is a pointer to the default env name
        if [[ "$env_name" == "__default__" ]]; then
          PROJECT_DEFAULT_ENV[$project_name]="$value"
          continue
        fi

        env_key="${project_name}:${env_name}"
        PROJECT_ENVS[$env_key]="$value"

        # First env added becomes default if none set
        if [[ -z "${PROJECT_DEFAULT_ENV[$project_name]:-}" ]]; then
          PROJECT_DEFAULT_ENV[$project_name]="$env_name"
        fi

        # If env is named "default", make it the default
        if [[ "$env_name" == "default" ]]; then
          PROJECT_DEFAULT_ENV[$project_name]="default"
        fi
      else
        # Regular project entry: name=/path
        PROJECTS[$key]="$value"
      fi

    done < "$CONFIG_FILE"
  fi
}

########################################
# CONFIG FILE HELPERS
########################################

# Remove all config lines for a project (path + envs)
config_remove_project() {
  local name=$1
  local tmpfile="${CONFIG_FILE}.tmp"
  grep -v "^${name}=" "$CONFIG_FILE" | grep -v "^${name}\.env\." > "$tmpfile" 2>/dev/null || true
  mv "$tmpfile" "$CONFIG_FILE"
}

# Remove a specific env line for a project
config_remove_env() {
  local name=$1
  local env_name=$2
  local tmpfile="${CONFIG_FILE}.tmp"
  grep -v "^${name}\.env\.${env_name}=" "$CONFIG_FILE" > "$tmpfile" 2>/dev/null || true
  mv "$tmpfile" "$CONFIG_FILE"
}

# Ensure config file exists
config_ensure() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << 'HEADER'
# Docker Project CLI (dk) - Project Configuration
# Format:
#   project_name=/path/to/project
#   project_name.env.default=docker-compose.yml
#   project_name.env.dev=docker-compose.dev.yml
HEADER
    echo "" >> "$CONFIG_FILE"
  fi
}

########################################
# DEPENDENCY CHECK
########################################

check_dependencies() {
  command -v docker >/dev/null 2>&1 || \
    error "Docker not installed" $EXIT_DEPENDENCY
  docker compose version >/dev/null 2>&1 || \
    error "Docker Compose v2 required" $EXIT_DEPENDENCY
}

########################################
# VALIDATORS
########################################

validate_project() {
  local name=$1
  if [[ -z "${PROJECTS[$name]:-}" ]]; then
    echo ""
    echo "Available projects:"
    for key in ${(k)PROJECTS}; do
      echo "  - $key"
    done
    error "Unknown project: $name" $EXIT_NOT_FOUND
  fi
}

validate_project_dir() {
  local dir=$1
  local project_name=$2

  [[ -d "$dir" ]] || error "Project directory not found: $dir" $EXIT_NOT_FOUND

  # If project has environments configured, validate the active one
  local active_env env_key
  active_env=$(get_active_env "$project_name")

  if [[ -n "$active_env" ]]; then
    env_key="${project_name}:${active_env}"
    local compose_file="${PROJECT_ENVS[$env_key]:-}"
    if [[ -n "$compose_file" ]]; then
      local resolved="$compose_file"
      [[ "$resolved" != /* ]] && resolved="$dir/$resolved"
      if [[ ! -f "$resolved" ]]; then
        error "Compose file not found: $resolved (env: $active_env)" $EXIT_NOT_FOUND
      fi
      return 0
    fi
  fi

  # No envs configured: auto-detect compose file in root
  if [[ ! -f "$dir/docker-compose.yml" && ! -f "$dir/docker-compose.yaml" && ! -f "$dir/compose.yml" && ! -f "$dir/compose.yaml" ]]; then
    error "No compose file found in $dir" $EXIT_NOT_FOUND
  fi
}

########################################
# ENVIRONMENT HELPERS
########################################

# Get the active environment for a project
# Priority: --env flag > project default > "default" env > first env > empty
get_active_env() {
  local project_name=$1
  local env_key

  # --env flag takes priority
  if [[ -n "$ENV_FLAG" ]]; then
    # Validate env exists
    env_key="${project_name}:${ENV_FLAG}"
    if [[ -z "${PROJECT_ENVS[$env_key]:-}" ]]; then
      error "Environment '${ENV_FLAG}' not found for project '${project_name}'. Run 'dk env ${project_name} list'" $EXIT_NOT_FOUND
    fi
    echo "$ENV_FLAG"
    return
  fi

  # Use project default
  if [[ -n "${PROJECT_DEFAULT_ENV[$project_name]:-}" ]]; then
    echo "${PROJECT_DEFAULT_ENV[$project_name]}"
    return
  fi

  # No environments configured
  echo ""
}

# Get list of environment names for a project
get_project_envs() {
  local project_name=$1
  local envs=()
  for key in ${(k)PROJECT_ENVS}; do
    if [[ "$key" == "${project_name}:"* ]]; then
      envs+=("${key#${project_name}:}")
    fi
  done
  echo "${envs[@]}"
}

# Check if a project has any environments configured
has_envs() {
  local project_name=$1
  for key in ${(k)PROJECT_ENVS}; do
    if [[ "$key" == "${project_name}:"* ]]; then
      return 0
    fi
  done
  return 1
}

# Scan a directory for compose files
scan_compose_files() {
  local dir=$1
  local files=()
  local f relpath

  # Phase 1: Check standard names in root
  for pattern in "docker-compose.yml" "docker-compose.yaml" "compose.yml" "compose.yaml" \
                 "docker-compose.*.yml" "docker-compose.*.yaml" "compose.*.yml" "compose.*.yaml"; do
    for f in "$dir"/$~pattern(N); do
      files+=("${f##*/}")
    done
  done

  # Phase 2: Check common subdirectories
  for subdir in "docker" "infra" ".docker" "deploy" "deployments" "devops"; do
    if [[ -d "$dir/$subdir" ]]; then
      for f in "$dir/$subdir"/*.yml(N) "$dir/$subdir"/*.yaml(N); do
        # Verify it's a compose file (contains "services:")
        if grep -q "^services:" "$f" 2>/dev/null; then
          relpath="${f#$dir/}"
          files+=("$relpath")
        fi
      done
    fi
  done

  # Phase 3: Deep scan - find any yml/yaml with "services:" up to 3 levels deep
  # Skip node_modules, .git, vendor, etc.
  for f in "$dir"/**/*.yml(N) "$dir"/**/*.yaml(N); do
    # Skip already found, hidden dirs, and common vendor dirs
    relpath="${f#$dir/}"
    [[ "$relpath" == node_modules/* ]] && continue
    [[ "$relpath" == .git/* ]] && continue
    [[ "$relpath" == vendor/* ]] && continue
    [[ "$relpath" == .cache/* ]] && continue

    # Skip if already in the list
    local already=false
    for existing in "${files[@]}"; do
      [[ "$existing" == "$relpath" ]] && already=true && break
    done
    [[ "$already" == true ]] && continue

    # Check depth (max 3 levels)
    local depth=$(echo "$relpath" | tr '/' '\n' | wc -l | tr -d ' ')
    [[ "$depth" -gt 3 ]] && continue

    # Verify it's a compose file
    if grep -q "^services:" "$f" 2>/dev/null; then
      files+=("$relpath")
    fi
  done

  # Deduplicate and sort
  printf '%s\n' "${files[@]}" | sort -u
}

########################################
# COMPOSE COMMAND HELPER
########################################

# Runs docker compose with the correct -f flags for the project + env
compose_cmd() {
  local project_name=$1
  local dir=$2
  shift 2

  local active_env env_key
  active_env=$(get_active_env "$project_name")

  if [[ -n "$active_env" ]]; then
    env_key="${project_name}:${active_env}"
    local compose_file="${PROJECT_ENVS[$env_key]:-}"
    if [[ -n "$compose_file" ]]; then
      local resolved="$compose_file"
      [[ "$resolved" != /* ]] && resolved="$dir/$resolved"
      docker compose -f "$resolved" "$@"
      return
    fi
  fi

  # No env configured: let docker compose auto-detect
  docker compose "$@"
}

get_project_state() {
  local project_name=$1
  local dir=$2
  local count

  count=$(cd "$dir" && compose_cmd "$project_name" "$dir" ps --status running -q 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$count" -gt 0 ]]; then
    echo "running ($count)"
  else
    echo "stopped"
  fi
}

get_dir_size() {
  du -sh "$1" 2>/dev/null | cut -f1 | tr -d ' '
}

safe_remove_dir() {
  local target=$1
  local skip_confirm=${2:-false}

  [[ -d "$target" ]] || return 0

  local size
  size=$(get_dir_size "$target")
  local name="${target##*/}"

  if [[ "$skip_confirm" == false ]]; then
    confirm "Delete ${name} (${size}) ?"
  fi

  log "Removing ${C_CYAN}${name}${C_RESET} ${C_DIM}(${size})${C_RESET}"
  rm -rf "$target" || { warn "Failed to remove $target"; return 1; }

  CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
  CLEANED_NAMES+=("${name} (${size})")
}

########################################
# HELP COMMAND
########################################

cmd_help() {

cat <<EOF

${C_BOLD}Docker Project CLI (dk) v${VERSION}${C_RESET}
--------------------------------------

A helper CLI to manage docker-compose projects safely.

${C_BOLD}USAGE${C_RESET}

  dk <command> <project> [--env <environment>] [options]

${C_BOLD}COMMANDS${C_RESET}

  ${C_CYAN}up${C_RESET} <project> [--build] [--env <env>]
      Start docker containers
      Use --build to rebuild images before starting
      Use --env to select a specific environment

  ${C_CYAN}stop${C_RESET} <project>
      Stop containers without removing them

  ${C_CYAN}down${C_RESET} <project> [--purge]
      Stop and remove containers (preserves volumes)
      Use --purge to also remove volumes

  ${C_CYAN}restart${C_RESET} <project>
      Restart containers

  ${C_CYAN}build${C_RESET} <project>
      Rebuild docker images without starting

  ${C_CYAN}logs${C_RESET} <project> [service] [--tail <N>]
      Stream docker logs

  ${C_CYAN}ps${C_RESET} <project>
      Show container status

  ${C_CYAN}exec${C_RESET} <project> <service> <command...>
      Execute a command inside a running container

  ${C_CYAN}shell${C_RESET} <project> <service>
      Open a shell (/bin/sh) in a running container

  ${C_CYAN}pull${C_RESET} <project>
      Pull latest images for the project

  ${C_CYAN}clean${C_RESET} <project> [--all] [--down] [--purge] [--force]
      Interactive cleanup of build artifacts, volumes, and images
      --all     Remove everything without selection prompt
      --down    Auto-stop containers without asking
      --purge   Stop containers + remove volumes
      --force   Skip all confirmations

  ${C_CYAN}add${C_RESET} <name> [path]  OR  ${C_CYAN}add${C_RESET} <path>
      Register a project with interactive compose file setup
      Auto-scans for compose files and asks about environments

  ${C_CYAN}remove${C_RESET} <name>
      Remove a project from config

  ${C_CYAN}env${C_RESET} <project> <action>
      Manage project environments:
      ${C_DIM}dk env backend list${C_RESET}                       Show environments
      ${C_DIM}dk env backend add <name> <file>${C_RESET}          Add environment
      ${C_DIM}dk env backend remove <name>${C_RESET}              Remove environment
      ${C_DIM}dk env backend default <name>${C_RESET}             Set default env

  ${C_CYAN}status${C_RESET}
      Show running state of all projects

  ${C_CYAN}list${C_RESET}
      List registered projects

  ${C_CYAN}init${C_RESET}
      Create a default config file

  ${C_CYAN}help${C_RESET}
      Show this help page


${C_BOLD}OPTIONS${C_RESET}

  --env <name> , -e <name>
      Select environment for the command

  --build , -b
      Rebuild images before starting (used with 'up')

  --purge , -p
      Remove docker volumes (used with 'down', 'clean')

  --force , -f
      Skip confirmation prompts

  --quiet , -q
      Suppress informational output

  --tail <N> , -t <N>
      Number of log lines to show (used with 'logs')

  --all
      Remove all artifacts without selection (used with 'clean')

  --down , -d
      Auto-stop containers (used with 'clean')


${C_BOLD}EXAMPLES${C_RESET}

  Start with default environment
      dk up backend

  Start with specific environment
      dk up backend --env dev

  Start with fresh build
      dk up backend --build --env prod

  Interactive clean (select what to remove)
      dk clean backend

  Remove everything
      dk clean backend --all --force

  Add a project (interactive)
      dk add backend ~/workspace/backend

  Add environment to existing project
      dk env backend add staging docker/compose.staging.yml

  Set default environment
      dk env backend default dev

  List environments
      dk env backend list


${C_BOLD}CONFIGURATION${C_RESET}

  Config file: $CONFIG_FILE

  Format:
    project_name=/path/to/project
    project_name.env.default=docker-compose.yml
    project_name.env.dev=docker-compose.dev.yml
    project_name.env.prod=docker/compose.prod.yml

  The first environment added becomes the default.
  Use 'dk env <project> default <name>' to change it.


${C_BOLD}SAFETY${C_RESET}

  This tool NEVER runs:
      docker system prune
      docker volume prune

  All actions are scoped only to the selected project.

EOF
}

########################################
# COMMANDS
########################################

cmd_up() {
  local project=$1
  local dir=$2

  (
    cd "$dir"
    local env_label
    env_label=$(get_active_env "$project")
    if [[ -n "$env_label" ]]; then
      log "Starting containers ${C_DIM}(env: ${env_label})${C_RESET}"
    else
      log "Starting containers"
    fi

    if [[ "$BUILD" == true ]]; then
      compose_cmd "$project" "$dir" up -d --build
    else
      compose_cmd "$project" "$dir" up -d
    fi
  )
}

cmd_down() {
  local project=$1
  local dir=$2

  (
    cd "$dir"
    if [[ "$PURGE" == true ]]; then
      confirm "This will delete Docker volumes (database data)"
      log "Stopping containers and removing volumes"
      compose_cmd "$project" "$dir" down --remove-orphans --volumes
    else
      log "Stopping containers (volumes preserved)"
      compose_cmd "$project" "$dir" down --remove-orphans
    fi
  )
}

cmd_stop() {
  local project=$1
  local dir=$2
  (
    cd "$dir"
    log "Stopping containers (not removing)"
    compose_cmd "$project" "$dir" stop
  )
}

cmd_build() {
  local project=$1
  local dir=$2
  (
    cd "$dir"
    log "Building images"
    compose_cmd "$project" "$dir" build
  )
}

cmd_logs() {
  local project=$1
  local dir=$2
  local service="${3:-}"

  (
    cd "$dir"
    local -a args=(logs -f)
    [[ -n "$TAIL" ]] && args+=(--tail "$TAIL")
    [[ -n "$service" ]] && args+=("$service")
    compose_cmd "$project" "$dir" "${args[@]}"
  )
}

cmd_ps() {
  local project=$1
  local dir=$2
  (
    cd "$dir"
    compose_cmd "$project" "$dir" ps
  )
}

cmd_restart() {
  local project=$1
  local dir=$2
  (
    cd "$dir"
    log "Restarting containers"
    compose_cmd "$project" "$dir" restart
  )
}

cmd_exec() {
  local project=$1
  local dir=$2
  local service=$3
  shift 3

  (
    cd "$dir"
    log "Executing in ${C_CYAN}$service${C_RESET}: $*"
    compose_cmd "$project" "$dir" exec "$service" "$@"
  )
}

cmd_shell() {
  local project=$1
  local dir=$2
  local service=$3

  (
    cd "$dir"
    log "Opening shell in ${C_CYAN}$service${C_RESET}"
    compose_cmd "$project" "$dir" exec "$service" /bin/sh
  )
}

cmd_pull() {
  local project=$1
  local dir=$2
  (
    cd "$dir"
    log "Pulling latest images"
    compose_cmd "$project" "$dir" pull
  )
}

########################################
# CLEAN COMMAND
########################################

cmd_clean() {
  local project=$1
  local dir=$2
  local artifacts=("node_modules" "dist" "build" ".next" ".cache" "__pycache__" ".parcel-cache" ".turbo" "coverage")
  local found_items=()
  local found_labels=()
  local found_types=()
  local state container_action=""
  local idx=0

  CLEANED_ITEMS=0
  CLEANED_NAMES=()

  echo ""
  echo "${C_BOLD}Clean: ${C_CYAN}${project}${C_RESET}"
  echo "${C_DIM}──────────────────────────────────────${C_RESET}"

  # ── Step 1: Handle containers ──
  state=$(get_project_state "$project" "$dir" 2>/dev/null || echo "unknown")

  if [[ "$state" == running* ]]; then
    echo ""
    echo "  ${C_GREEN}●${C_RESET}  Containers: ${C_GREEN}${state}${C_RESET}"

    if [[ "$CLEAN_DOWN" == true || "$PURGE" == true || "$CLEAN_ALL" == true ]]; then
      container_action="down"
    elif [[ "$FORCE" != true ]]; then
      echo ""
      local stop_ans
      stop_ans=$(ask "  ${C_YELLOW}?${C_RESET} Stop containers first? (y/N): ")
      if [[ "$stop_ans" == "y" || "$stop_ans" == "Y" ]]; then
        container_action="down"
      fi
    fi

    if [[ "$container_action" == "down" ]]; then
      echo ""
      if [[ "$PURGE" == true ]]; then
        log "Stopping containers + removing volumes..."
        (cd "$dir" && compose_cmd "$project" "$dir" down -v 2>/dev/null) || warn "Failed to stop containers"
      else
        log "Stopping containers..."
        (cd "$dir" && compose_cmd "$project" "$dir" down 2>/dev/null) || warn "Failed to stop containers"
      fi
    fi
  elif [[ "$state" == "stopped" ]]; then
    echo ""
    echo "  ${C_DIM}○${C_RESET}  Containers: ${C_DIM}stopped${C_RESET}"
  fi

  # ── Step 2: Scan everything ──
  echo ""
  log "Scanning..."
  echo ""

  # Scan build artifacts
  for artifact in "${artifacts[@]}"; do
    if [[ -d "$dir/$artifact" ]]; then
      local size
      size=$(get_dir_size "$dir/$artifact")
      idx=$((idx + 1))
      found_items+=("$dir/$artifact")
      found_labels+=("${artifact} (${size})")
      found_types+=("artifact")
      echo "  ${C_WHITE}${idx})${C_RESET}  ${artifact}  ${C_DIM}(${size})${C_RESET}"
    fi
  done

  # Scan docker volumes for this project
  local volume_count=0
  local volume_list=""
  if command -v docker >/dev/null 2>&1; then
    local project_dir_name="${dir##*/}"
    volume_list=$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -i "^${project_dir_name}" 2>/dev/null || true)
    if [[ -n "$volume_list" ]]; then
      volume_count=$(echo "$volume_list" | wc -l | tr -d ' ')
      idx=$((idx + 1))
      found_items+=("__volumes__")
      found_labels+=("Docker volumes (${volume_count} volumes)")
      found_types+=("volume")
      echo "  ${C_WHITE}${idx})${C_RESET}  Docker volumes  ${C_DIM}(${volume_count} volumes)${C_RESET}"
    fi
  fi

  # Scan docker images for this project
  local image_count=0
  local image_list=""
  if command -v docker >/dev/null 2>&1; then
    local project_dir_name="${dir##*/}"
    image_list=$(docker images --format '{{.Repository}}:{{.Tag}} {{.Size}}' 2>/dev/null | grep -i "^${project_dir_name}" 2>/dev/null || true)
    if [[ -n "$image_list" ]]; then
      image_count=$(echo "$image_list" | wc -l | tr -d ' ')
      idx=$((idx + 1))
      found_items+=("__images__")
      found_labels+=("Docker images (${image_count} images)")
      found_types+=("image")
      echo "  ${C_WHITE}${idx})${C_RESET}  Docker images  ${C_DIM}(${image_count} images)${C_RESET}"
    fi
  fi

  if [[ $idx -eq 0 ]]; then
    echo "  ${C_GREEN}✔${C_RESET}  Nothing to clean"
    echo ""
    return 0
  fi

  # ── Step 3: Selection ──
  echo ""
  local selected=()

  if [[ "$CLEAN_ALL" == true || "$FORCE" == true ]]; then
    # Select everything
    for i in $(seq 1 $idx); do
      selected+=($i)
    done
  else
    echo "  ${C_DIM}Enter selection:${C_RESET}"
    echo "  ${C_DIM}  a = all, n = none, 1,3 = specific items${C_RESET}"
    echo ""
    local selection
    selection=$(ask "  ${C_CYAN}?${C_RESET} Remove which? ")

    if [[ "$selection" == "n" || "$selection" == "N" || -z "$selection" ]]; then
      echo ""
      echo "  Nothing removed."
      echo ""
      return 0
    elif [[ "$selection" == "a" || "$selection" == "A" ]]; then
      for i in $(seq 1 $idx); do
        selected+=($i)
      done
    else
      # Parse comma-separated numbers
      local IFS=','
      for num in $selection; do
        num="${num## }"; num="${num%% }"
        if [[ "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le $idx ]]; then
          selected+=($num)
        fi
      done
    fi
  fi

  if [[ ${#selected[@]} -eq 0 ]]; then
    echo ""
    echo "  Nothing selected."
    echo ""
    return 0
  fi

  # ── Step 4: Execute removal ──
  echo ""

  for sel in "${selected[@]}"; do
    local item="${found_items[$sel]}"
    local label="${found_labels[$sel]}"
    local type="${found_types[$sel]}"

    case "$type" in
      artifact)
        safe_remove_dir "$item" true
        ;;
      volume)
        log "Removing Docker volumes..."
        echo "$volume_list" | while read -r vol; do
          [[ -n "$vol" ]] && docker volume rm "$vol" 2>/dev/null && \
            echo "    ${C_DIM}→ removed: ${vol}${C_RESET}"
        done
        CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
        CLEANED_NAMES+=("$label")
        ;;
      image)
        log "Removing Docker images..."
        echo "$image_list" | while read -r img_line; do
          local img_name="${img_line%% *}"
          [[ -n "$img_name" ]] && docker rmi "$img_name" 2>/dev/null && \
            echo "    ${C_DIM}→ removed: ${img_name}${C_RESET}"
        done
        CLEANED_ITEMS=$((CLEANED_ITEMS + 1))
        CLEANED_NAMES+=("$label")
        ;;
    esac
  done

  # ── Step 5: Summary ──
  echo ""
  echo "${C_DIM}──────────────────────────────────────${C_RESET}"
  echo "${C_BOLD}Summary${C_RESET}"
  echo ""
  echo "  Items removed: ${C_CYAN}${CLEANED_ITEMS}${C_RESET}"
  for item in "${CLEANED_NAMES[@]}"; do
    echo "    ${C_DIM}→ ${item}${C_RESET}"
  done
  if [[ "$container_action" == "down" ]]; then
    if [[ "$PURGE" == true ]]; then
      echo "  Containers: ${C_RED}stopped + volumes removed${C_RESET}"
    else
      echo "  Containers: ${C_YELLOW}stopped${C_RESET}"
    fi
  fi
  echo ""
}

########################################
# LIST / STATUS COMMANDS
########################################

cmd_list() {

  local dir state state_icon state_label key env_info default_env env_display ename ekey

  echo ""
  echo "${C_BOLD}Registered Docker Projects${C_RESET}"
  echo "${C_DIM}──────────────────────────────────────${C_RESET}"
  echo ""

  for key in ${(k)PROJECTS}; do
    dir="${PROJECTS[$key]}"

    if [[ -d "$dir" ]]; then
      state=$(get_project_state "$key" "$dir" 2>/dev/null || echo "unknown")
    else
      state="dir missing"
    fi

    case "$state" in
      running*)
        state_icon="${C_GREEN}●${C_RESET}"
        state_label="${C_GREEN}${state}${C_RESET}"
        ;;
      stopped)
        state_icon="${C_DIM}○${C_RESET}"
        state_label="${C_DIM}${state}${C_RESET}"
        ;;
      *)
        state_icon="${C_RED}✖${C_RESET}"
        state_label="${C_RED}${state}${C_RESET}"
        ;;
    esac

    echo "  ${state_icon}  ${C_CYAN}${key}${C_RESET}"
    echo "     ${C_DIM}${dir}${C_RESET}  ${state_label}"

    # Show environments if configured (inline to avoid subshell issues)
    default_env="${PROJECT_DEFAULT_ENV[$key]:-}"
    env_display=""
    for ekey in ${(k)PROJECT_ENVS}; do
      if [[ "$ekey" == "${key}:"* ]]; then
        ename="${ekey#${key}:}"
        if [[ "$ename" == "$default_env" ]]; then
          env_display="${env_display} ${C_GREEN}${ename}*${C_RESET}"
        else
          env_display="${env_display} ${C_DIM}${ename}${C_RESET}"
        fi
      fi
    done
    if [[ -n "$env_display" ]]; then
      echo "     envs:${env_display}"
    fi
    echo ""
  done

  echo "${C_DIM}──────────────────────────────────────${C_RESET}"
  if [[ -f "$CONFIG_FILE" ]]; then
    echo "${C_DIM}Config: $CONFIG_FILE${C_RESET}"
  else
    echo "${C_DIM}No config file. Run 'dk init' to create one.${C_RESET}"
  fi
  echo ""
}

cmd_status() {

  local dir state key

  echo ""
  echo "${C_BOLD}Project Status Overview${C_RESET}"
  echo "${C_DIM}──────────────────────────────────────${C_RESET}"
  echo ""

  for key in ${(k)PROJECTS}; do
    dir="${PROJECTS[$key]}"

    if [[ ! -d "$dir" ]]; then
      echo "  ${C_RED}✖${C_RESET}  ${C_CYAN}${key}${C_RESET}  ${C_DIM}(directory missing)${C_RESET}"
      continue
    fi

    state=$(get_project_state "$key" "$dir" 2>/dev/null || echo "unknown")

    case "$state" in
      running*)
        echo "  ${C_GREEN}●${C_RESET}  ${C_CYAN}${key}${C_RESET}  ${C_GREEN}${state}${C_RESET}"
        ;;
      stopped)
        echo "  ${C_DIM}○${C_RESET}  ${C_CYAN}${key}${C_RESET}  ${C_DIM}${state}${C_RESET}"
        ;;
      *)
        echo "  ${C_YELLOW}?${C_RESET}  ${C_CYAN}${key}${C_RESET}  ${C_YELLOW}${state}${C_RESET}"
        ;;
    esac
  done

  echo ""
  echo "${C_DIM}──────────────────────────────────────${C_RESET}"
  echo ""
}

########################################
# INIT COMMAND
########################################

cmd_init() {

  if [[ -f "$CONFIG_FILE" ]]; then
    warn "Config file already exists: $CONFIG_FILE"
    confirm "Overwrite existing config file?"
  fi

  mkdir -p "$CONFIG_DIR"

  cat > "$CONFIG_FILE" << 'CONF'
# Docker Project CLI (dk) v2 - Project Configuration
#
# Format:
#   project_name=/path/to/project
#   project_name.env.default=docker-compose.yml
#   project_name.env.dev=docker-compose.dev.yml
#   project_name.env.prod=docker/compose.prod.yml
#
# The first environment added becomes the default.
# Lines starting with # are comments.
# Use ~ or $HOME for home directory.

# Example:
# backend=~/workspace/backend
# backend.env.default=docker-compose.yml
# backend.env.dev=docker-compose.dev.yml
CONF

  log "Config file created: ${C_CYAN}$CONFIG_FILE${C_RESET}"
}

########################################
# ADD COMMAND (interactive)
########################################

# Helper: interactively add manual environment entries
# Helper: interactive checkbox selector
# Renders a list with ↑/↓ navigation, space to toggle, enter to confirm
# Usage: _checkbox_select <item1> <item2> ...
# Sets CHECKBOX_RESULT=() with selected indices (1-based)
_checkbox_select() {
  local -a items=("$@")
  local count=${#items[@]}
  local cursor=1
  CHECKBOX_RESULT=()

  # Initialize checked state
  local i
  for ((i = 1; i <= count; i++)); do
    eval "_CB_CHECKED_${i}=0"
  done

  # Total lines: items + 1 blank + 1 hint
  local total_lines=$((count + 2))

  # Save terminal state and hide cursor
  local saved_tty
  saved_tty=$(stty -g 2>/dev/null)
  printf '\033[?25l'

  # Trap to restore on exit
  trap 'printf "\033[?25h"; stty "$saved_tty" 2>/dev/null' INT TERM

  # Draw function (inline to avoid scope issues)
  _cb_draw() {
    local ii
    for ((ii = 1; ii <= count; ii++)); do
      local cb_var="_CB_CHECKED_${ii}"
      local marker="○"
      [[ "${(P)cb_var}" == "1" ]] && marker="●"

      if [[ $ii -eq $cursor ]]; then
        if [[ "${(P)cb_var}" == "1" ]]; then
          printf '\033[2K  \033[36m❯\033[0m  \033[32m●\033[0m  %s\n' "${items[$ii]}"
        else
          printf '\033[2K  \033[36m❯\033[0m  \033[2m○\033[0m  %s\n' "${items[$ii]}"
        fi
      else
        if [[ "${(P)cb_var}" == "1" ]]; then
          printf '\033[2K     \033[32m●\033[0m  %s\n' "${items[$ii]}"
        else
          printf '\033[2K     \033[2m○\033[0m  %s\n' "${items[$ii]}"
        fi
      fi
    done
    printf '\033[2K\n'
    printf '\033[2K  \033[2m↑/↓ navigate  ·  space toggle  ·  a all  ·  enter confirm\033[0m\n'
  }

  # Initial draw
  _cb_draw

  # Input loop
  while true; do
    local key=""
    read -rsk1 key 2>/dev/null

    if [[ "$key" == $'\e' ]]; then
      local seq1="" seq2=""
      read -rsk1 -t 0.1 seq1 2>/dev/null
      read -rsk1 -t 0.1 seq2 2>/dev/null

      if [[ "$seq1" == "[" ]]; then
        case "$seq2" in
          A) cursor=$((cursor - 1)); [[ $cursor -lt 1 ]] && cursor=$count ;;
          B) cursor=$((cursor + 1)); [[ $cursor -gt $count ]] && cursor=1 ;;
        esac
      fi
    elif [[ "$key" == " " ]]; then
      local cb_var="_CB_CHECKED_${cursor}"
      if [[ "${(P)cb_var}" == "1" ]]; then
        eval "_CB_CHECKED_${cursor}=0"
      else
        eval "_CB_CHECKED_${cursor}=1"
      fi
    elif [[ "$key" == "a" || "$key" == "A" ]]; then
      local all_checked=true
      for ((i = 1; i <= count; i++)); do
        local cb_var="_CB_CHECKED_${i}"
        [[ "${(P)cb_var}" != "1" ]] && all_checked=false && break
      done
      for ((i = 1; i <= count; i++)); do
        [[ "$all_checked" == true ]] && eval "_CB_CHECKED_${i}=0" || eval "_CB_CHECKED_${i}=1"
      done
    elif [[ "$key" == $'\n' || "$key" == $'\r' || "$key" == "" ]]; then
      break
    fi

    # Move up and redraw
    printf '\033[%dA' "$total_lines"
    _cb_draw
  done

  # Restore terminal state and show cursor
  stty "$saved_tty" 2>/dev/null
  printf '\033[?25h'
  trap - INT TERM

  # Clear interactive display and show final summary
  printf '\033[%dA' "$total_lines"
  for ((i = 1; i <= total_lines; i++)); do
    printf '\033[2K\n'
  done
  printf '\033[%dA' "$total_lines"

  # Print selected items
  for ((i = 1; i <= count; i++)); do
    local cb_var="_CB_CHECKED_${i}"
    if [[ "${(P)cb_var}" == "1" ]]; then
      CHECKBOX_RESULT+=($i)
      printf '  \033[32m●\033[0m  %s\n' "${items[$i]}"
    fi
  done

  # Cleanup variables
  for ((i = 1; i <= count; i++)); do
    unset "_CB_CHECKED_${i}"
  done
}

# Helper: select compose files from list and name them as envs
# Usage: _add_pick_envs <project_name> <file1> <file2> ...
_add_pick_envs() {
  local name=$1
  shift
  local pick_files=("$@")
  local pick_count=${#pick_files[@]}

  echo ""
  echo "  ${C_BOLD}Select compose files to add as environments:${C_RESET}"
  echo ""

  _checkbox_select "${pick_files[@]}"

  if [[ ${#CHECKBOX_RESULT[@]} -eq 0 ]]; then
    echo ""
    echo "  ${C_DIM}No files selected.${C_RESET}"
    return
  fi

  # Ask env name for each selected file
  echo ""
  local env_name_input
  for si in "${CHECKBOX_RESULT[@]}"; do
    local selected_file="${pick_files[$si]}"
    env_name_input=$(ask "  ${C_DIM}${selected_file}${C_RESET} -> env name: ")

    if [[ -n "$env_name_input" ]]; then
      env_name_input="${env_name_input// /-}"
      echo "${name}.env.${env_name_input}=${selected_file}" >> "$CONFIG_FILE"
      echo "  ${C_GREEN}✔${C_RESET}  ${env_name_input} -> ${selected_file}"
    else
      echo "  ${C_DIM}Skipped ${selected_file}${C_RESET}"
    fi
  done
}

_add_manual_env() {
  local name=$1
  local dir=$2
  local env_name_input file_path_input resolved

  echo ""
  echo "  ${C_DIM}Enter environment name and compose file path.${C_RESET}"
  echo "  ${C_DIM}Leave name empty to stop adding.${C_RESET}"
  echo ""

  while true; do
    env_name_input=$(ask "  ${C_CYAN}?${C_RESET} Environment name (or Enter to finish): ")
    [[ -z "$env_name_input" ]] && break

    # Sanitize
    env_name_input="${env_name_input// /-}"

    file_path_input=$(ask "  ${C_CYAN}?${C_RESET} Compose file path: ")
    [[ -z "$file_path_input" ]] && { warn "Skipped (no file path)"; echo ""; continue; }

    # Validate file exists
    resolved="$file_path_input"
    [[ "$resolved" != /* ]] && resolved="$dir/$resolved"

    if [[ ! -f "$resolved" ]]; then
      warn "File not found: $resolved"
      local add_anyway
      add_anyway=$(ask "  ${C_YELLOW}?${C_RESET} Add anyway? (y/N): ")
      if [[ "$add_anyway" != "y" && "$add_anyway" != "Y" ]]; then
        echo ""
        continue
      fi
    fi

    echo "${name}.env.${env_name_input}=${file_path_input}" >> "$CONFIG_FILE"
    echo "  ${C_GREEN}✔${C_RESET}  ${env_name_input} -> ${file_path_input}"
    echo ""
  done
}

# Helper: print add summary
_add_summary() {
  local name=$1
  local dir=$2
  local added_envs=0 k v ename

  echo ""
  echo "${C_DIM}──────────────────────────────────────${C_RESET}"
  log "Added project: ${C_CYAN}${name}${C_RESET} -> ${dir}"

  while IFS='=' read -r k v; do
    if [[ "$k" == "${name}.env."* ]]; then
      ename="${k##*.env.}"
      [[ "$ename" == "__default__" ]] && continue
      if [[ $added_envs -eq 0 ]]; then
        echo ""
        echo "  ${C_BOLD}Environments:${C_RESET}"
      fi
      added_envs=$((added_envs + 1))
      echo "    ${C_CYAN}${ename}${C_RESET} -> ${v}"
    fi
  done < "$CONFIG_FILE"

  echo ""
}

cmd_add() {

  local name=$1
  local dir="${2:-}"

  # If only one arg and it looks like a path, derive name
  if [[ -z "$dir" && "$name" == */* ]]; then
    dir="$name"
    name="${dir:t}"
    [[ -z "$name" ]] && name="${dir%/}" && name="${name:t}"
  fi

  [[ -z "$dir" ]] && dir="$(pwd)"
  dir="${dir:a}"

  # Validate name
  if [[ ! "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "Invalid project name: '$name' (use only letters, numbers, hyphens, underscores)" $EXIT_USAGE
  fi

  # Validate directory
  [[ -d "$dir" ]] || error "Directory not found: $dir" $EXIT_NOT_FOUND

  # Ensure config exists
  config_ensure

  # Handle existing project — if it already has a default env, skip to adding more
  if grep -q "^${name}=" "$CONFIG_FILE" 2>/dev/null; then
    local existing
    existing=$(grep "^${name}=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-)

    # Check if project has a default env configured
    local has_default=false
    if grep -q "^${name}\.env\." "$CONFIG_FILE" 2>/dev/null; then
      has_default=true
    fi

    if [[ "$has_default" == true ]]; then
      echo ""
      echo "${C_BOLD}Project: ${C_CYAN}${name}${C_RESET} ${C_DIM}(${existing})${C_RESET}"
      echo "${C_DIM}──────────────────────────────────────${C_RESET}"
      echo ""

      # Show existing envs
      echo "  ${C_BOLD}Current environments:${C_RESET}"
      while IFS='=' read -r k v; do
        if [[ "$k" == "${name}.env."* && "$k" != *"__default__" ]]; then
          local ename="${k#${name}.env.}"
          echo "  ${C_GREEN}✔${C_RESET}  ${ename} -> ${v}"
        fi
      done < "$CONFIG_FILE"
      echo ""

      # Scan for compose files to offer options
      log "Scanning for compose files..."
      echo ""
      local compose_files
      compose_files=$(scan_compose_files "$existing")

      local file_array=()
      if [[ -n "$compose_files" ]]; then
        while read -r f; do
          [[ -n "$f" ]] && file_array+=("$f")
        done <<< "$compose_files"
      fi

      # Filter out files already configured as envs
      local remaining_files=()
      for f in "${file_array[@]}"; do
        local already_added=false
        while IFS='=' read -r k v; do
          if [[ "$k" == "${name}.env."* && "$v" == "$f" ]]; then
            already_added=true
            break
          fi
        done < "$CONFIG_FILE"
        [[ "$already_added" == false ]] && remaining_files+=("$f")
      done

      local remaining_count=${#remaining_files[@]}

      if [[ $remaining_count -gt 0 ]]; then
        echo "  ${C_BOLD}Unassigned compose files:${C_RESET}"
        local idx=0
        for f in "${remaining_files[@]}"; do
          idx=$((idx + 1))
          echo "  ${C_WHITE}${idx})${C_RESET}  ${f}"
        done
        echo ""

        echo "  ${C_DIM}How would you like to add environments?${C_RESET}"
        echo ""
        echo "  ${C_WHITE}1)${C_RESET}  Pick from scanned files"
        echo "  ${C_WHITE}2)${C_RESET}  Enter paths manually"
        echo "  ${C_WHITE}3)${C_RESET}  Both"
        echo "  ${C_WHITE}s)${C_RESET}  Skip"
        echo ""
        local env_method
        env_method=$(ask "  ${C_CYAN}?${C_RESET} Choice (1/2/3/s): ")

        if [[ "$env_method" == "1" || "$env_method" == "3" ]]; then
          _add_pick_envs "$name" "${remaining_files[@]}"
        fi

        if [[ "$env_method" == "2" || "$env_method" == "3" ]]; then
          _add_manual_env "$name" "$existing"
        fi
      else
        echo "  ${C_DIM}No unassigned compose files found.${C_RESET}"
        echo ""
        local add_manual
        add_manual=$(ask "  ${C_CYAN}?${C_RESET} Add environments manually? (y/N): ")
        if [[ "$add_manual" == "y" || "$add_manual" == "Y" ]]; then
          _add_manual_env "$name" "$existing"
        fi
      fi

      _add_summary "$name" "$existing"
      return 0
    else
      # Project exists but no envs — offer overwrite
      warn "Project '${name}' already exists: $existing"
      confirm "Overwrite?"
      config_remove_project "$name"
    fi
  fi

  echo ""
  echo "${C_BOLD}Adding project: ${C_CYAN}${name}${C_RESET}"
  echo "${C_DIM}──────────────────────────────────────${C_RESET}"
  echo ""

  # Write project path
  echo "${name}=${dir}" >> "$CONFIG_FILE"

  # ── Scan for compose files ──
  log "Scanning for compose files..."
  echo ""

  local compose_files
  compose_files=$(scan_compose_files "$dir")

  # Build file array from scan results
  local file_array=()
  if [[ -n "$compose_files" ]]; then
    while read -r f; do
      [[ -n "$f" ]] && file_array+=("$f")
    done <<< "$compose_files"
  fi

  local file_count=${#file_array[@]}

  if [[ $file_count -eq 0 ]]; then
    warn "No compose files found in $dir"
    echo ""
    echo "  ${C_DIM}m)${C_RESET}  Enter path manually"
    echo "  ${C_DIM}s)${C_RESET}  Skip (add later with: dk env ${name} add <env> <file>)"
    echo ""
    local manual_pick
    manual_pick=$(ask "  ${C_CYAN}?${C_RESET} Choice: ")

    if [[ "$manual_pick" == "m" || "$manual_pick" == "M" ]]; then
      _add_manual_env "$name" "$dir"
    else
      echo ""
      log "Added project: ${C_CYAN}${name}${C_RESET} -> ${dir} ${C_DIM}(no environments)${C_RESET}"
    fi
    return 0
  fi

  # Display found files with numbering
  local idx=0
  for f in "${file_array[@]}"; do
    idx=$((idx + 1))
    echo "  ${C_WHITE}${idx})${C_RESET}  ${f}"
  done
  echo ""
  echo "  ${C_DIM}m)${C_RESET}  Enter path manually"
  echo "  ${C_DIM}s)${C_RESET}  Skip environments"
  echo ""

  # ── Single file: auto-select as default ──
  if [[ $file_count -eq 1 ]]; then
    local single_file="${file_array[1]}"
    echo "${name}.env.default=${single_file}" >> "$CONFIG_FILE"
    echo "  ${C_GREEN}✔${C_RESET}  default -> ${single_file}"

    # Ask if they want to add more environments
    echo ""
    local more
    more=$(ask "  ${C_CYAN}?${C_RESET} Add other compose files as environments? (y/N): ")
    if [[ "$more" == "y" || "$more" == "Y" ]]; then
      _add_manual_env "$name" "$dir"
    fi

    _add_summary "$name" "$dir"
    return 0
  fi

  # ── Multiple files: interactive setup ──

  # Step 1: Pick the default
  echo "  ${C_DIM}Which file should be the ${C_RESET}${C_BOLD}default${C_RESET}${C_DIM} environment?${C_RESET}"
  echo "  ${C_DIM}Enter number (1-${file_count}), 'm' for manual, or 's' to skip:${C_RESET}"
  echo ""
  local default_pick
  default_pick=$(ask "  ${C_CYAN}?${C_RESET} Default: ")

  local default_file=""
  if [[ "$default_pick" == "m" || "$default_pick" == "M" ]]; then
    echo ""
    local manual_path
    manual_path=$(ask "  ${C_CYAN}?${C_RESET} Enter compose file path (relative to project): ")
    if [[ -n "$manual_path" ]]; then
      local resolved="$manual_path"
      [[ "$resolved" != /* ]] && resolved="$dir/$resolved"
      if [[ -f "$resolved" ]]; then
        default_file="$manual_path"
        echo "${name}.env.default=${default_file}" >> "$CONFIG_FILE"
        echo "  ${C_GREEN}✔${C_RESET}  default -> ${default_file}"
      else
        warn "File not found: $resolved"
      fi
    fi
  elif [[ "$default_pick" =~ ^[0-9]+$ && "$default_pick" -ge 1 && "$default_pick" -le $file_count ]]; then
    default_file="${file_array[$default_pick]}"
    echo "${name}.env.default=${default_file}" >> "$CONFIG_FILE"
    echo "  ${C_GREEN}✔${C_RESET}  default -> ${default_file}"
  fi

  # Step 2: Ask about remaining scanned files
  echo ""
  local add_more
  add_more=$(ask "  ${C_CYAN}?${C_RESET} Add other compose files as environments? (y/N): ")

  if [[ "$add_more" == "y" || "$add_more" == "Y" ]]; then
    echo ""
    echo "  ${C_DIM}How would you like to add environments?${C_RESET}"
    echo ""
    echo "  ${C_WHITE}1)${C_RESET}  Pick from scanned files"
    echo "  ${C_WHITE}2)${C_RESET}  Enter paths manually"
    echo "  ${C_WHITE}3)${C_RESET}  Both"
    echo ""
    local env_method
    env_method=$(ask "  ${C_CYAN}?${C_RESET} Choice (1/2/3): ")

    # Option 1 or 3: Pick from scanned list
    if [[ "$env_method" == "1" || "$env_method" == "3" ]]; then
      # Build list excluding default
      local pick_list=()
      for f in "${file_array[@]}"; do
        [[ "$f" == "$default_file" ]] && continue
        pick_list+=("$f")
      done
      if [[ ${#pick_list[@]} -gt 0 ]]; then
        _add_pick_envs "$name" "${pick_list[@]}"
      fi
    fi

    # Option 2 or 3: Manual entry
    if [[ "$env_method" == "2" || "$env_method" == "3" ]]; then
      _add_manual_env "$name" "$dir"
    fi
  fi

  _add_summary "$name" "$dir"
}

########################################
# REMOVE COMMAND
########################################

cmd_remove() {

  local name=$1

  if [[ ! -f "$CONFIG_FILE" ]]; then
    error "No config file found. Run 'dk init' first." $EXIT_NOT_FOUND
  fi

  if ! grep -q "^${name}=" "$CONFIG_FILE" 2>/dev/null; then
    error "Project '${name}' not found in config" $EXIT_NOT_FOUND
  fi

  local existing
  existing=$(grep "^${name}=" "$CONFIG_FILE" | head -1 | cut -d'=' -f2-)

  # Show what will be removed
  echo ""
  echo "  Project: ${C_CYAN}${name}${C_RESET}"
  echo "  Path:    ${existing}"

  local env_count=0
  while IFS='=' read -r k v; do
    [[ "$k" == "${name}.env."* ]] && env_count=$((env_count + 1))
  done < "$CONFIG_FILE"

  if [[ $env_count -gt 0 ]]; then
    echo "  Envs:    ${env_count} environment(s) will also be removed"
  fi

  confirm "Remove project '${name}' and all its environments?"

  config_remove_project "$name"
  log "Removed project: ${C_CYAN}${name}${C_RESET}"
}

########################################
# ENV COMMAND
########################################

cmd_env() {

  local project=$1
  local action="${2:-list}"

  # Reload config to pick up any recent changes
  load_config

  # Validate project exists
  if [[ -z "${PROJECTS[$project]:-}" ]]; then
    error "Unknown project: $project" $EXIT_NOT_FOUND
  fi

  local dir="${PROJECTS[$project]}"

  case "$action" in

    list)
      echo ""
      echo "${C_BOLD}Environments: ${C_CYAN}${project}${C_RESET}"
      echo "${C_DIM}──────────────────────────────────────${C_RESET}"
      echo ""

      local default_env="${PROJECT_DEFAULT_ENV[$project]:-}"
      local found=false

      for key in ${(k)PROJECT_ENVS}; do
        if [[ "$key" == "${project}:"* ]]; then
          found=true
          local ename="${key#${project}:}"
          local efile="${PROJECT_ENVS[$key]}"
          local resolved="$efile"
          [[ "$resolved" != /* ]] && resolved="$dir/$resolved"
          local exists_icon="${C_GREEN}✔${C_RESET}"
          [[ ! -f "$resolved" ]] && exists_icon="${C_RED}✖${C_RESET}"

          if [[ "$ename" == "$default_env" ]]; then
            echo "  ${exists_icon}  ${C_CYAN}${ename}${C_RESET} ${C_GREEN}(default)${C_RESET}"
          else
            echo "  ${exists_icon}  ${C_CYAN}${ename}${C_RESET}"
          fi
          echo "     ${C_DIM}${efile}${C_RESET}"
          echo ""
        fi
      done

      if [[ "$found" == false ]]; then
        echo "  ${C_DIM}No environments configured.${C_RESET}"
        echo "  ${C_DIM}Compose file is auto-detected from project root.${C_RESET}"
        echo ""
        echo "  Add one with: dk env ${project} add <name> <file>"
        echo ""
      fi
      ;;

    info)
      local env_name="${3:-}"

      if [[ -z "$env_name" ]]; then
        error "Usage: dk env $project info <name>" $EXIT_USAGE
      fi

      local check_key="${project}:${env_name}"
      if [[ -z "${PROJECT_ENVS[$check_key]:-}" ]]; then
        error "Environment '${env_name}' not found for project '${project}'" $EXIT_NOT_FOUND
      fi

      local efile="${PROJECT_ENVS[$check_key]}"
      local resolved="$efile"
      [[ "$resolved" != /* ]] && resolved="$dir/$resolved"

      local default_env="${PROJECT_DEFAULT_ENV[$project]:-}"
      local is_default="No"
      [[ "$env_name" == "$default_env" ]] && is_default="Yes"

      local file_exists="${C_GREEN}Yes${C_RESET}"
      local file_size="-"
      local service_list=""
      if [[ -f "$resolved" ]]; then
        file_size=$(du -h "$resolved" 2>/dev/null | cut -f1 | xargs)
        # Extract service names from compose file
        service_list=$(grep -E '^\s{2}[a-zA-Z0-9_-]+:\s*$' "$resolved" 2>/dev/null | sed 's/://;s/^[[:space:]]*//' | tr '\n' ', ' | sed 's/,$//')
      else
        file_exists="${C_RED}No${C_RESET}"
      fi

      echo ""
      echo "${C_BOLD}Environment: ${C_CYAN}${env_name}${C_RESET}"
      echo "${C_DIM}──────────────────────────────────────${C_RESET}"
      echo ""
      echo "  ${C_BOLD}Project:${C_RESET}      ${project}"
      echo "  ${C_BOLD}Project dir:${C_RESET}  ${dir}"
      echo "  ${C_BOLD}Compose file:${C_RESET} ${efile}"
      echo "  ${C_BOLD}Full path:${C_RESET}    ${resolved}"
      echo "  ${C_BOLD}File exists:${C_RESET}  ${file_exists}"
      echo "  ${C_BOLD}File size:${C_RESET}    ${file_size}"
      echo "  ${C_BOLD}Default:${C_RESET}      ${is_default}"
      if [[ -n "$service_list" ]]; then
        echo "  ${C_BOLD}Services:${C_RESET}     ${service_list}"
      fi
      echo ""
      ;;

    add)
      local env_name="${3:-}"
      local env_file="${4:-}"

      if [[ -z "$env_name" || -z "$env_file" ]]; then
        error "Usage: dk env $project add <name> <compose-file>" $EXIT_USAGE
      fi

      # Validate compose file exists
      local resolved="$env_file"
      [[ "$resolved" != /* ]] && resolved="$dir/$resolved"
      if [[ ! -f "$resolved" ]]; then
        error "Compose file not found: $resolved" $EXIT_NOT_FOUND
      fi

      # Check if env already exists
      local check_key="${project}:${env_name}"
      if [[ -n "${PROJECT_ENVS[$check_key]:-}" ]]; then
        warn "Environment '${env_name}' already exists: ${PROJECT_ENVS[$check_key]}"
        confirm "Overwrite?"
        config_remove_env "$project" "$env_name"
      fi

      config_ensure
      echo "${project}.env.${env_name}=${env_file}" >> "$CONFIG_FILE"
      log "Added environment: ${C_CYAN}${env_name}${C_RESET} -> ${env_file}"
      ;;

    remove|rm)
      local env_name="${3:-}"

      if [[ -z "$env_name" ]]; then
        error "Usage: dk env $project remove <name>" $EXIT_USAGE
      fi

      local check_key="${project}:${env_name}"
      if [[ -z "${PROJECT_ENVS[$check_key]:-}" ]]; then
        error "Environment '${env_name}' not found for project '${project}'" $EXIT_NOT_FOUND
      fi

      confirm "Remove environment '${env_name}'?"
      config_remove_env "$project" "$env_name"
      log "Removed environment: ${C_CYAN}${env_name}${C_RESET}"
      ;;

    update|set)
      local env_name="${3:-}"
      local env_file="${4:-}"

      if [[ -z "$env_name" ]]; then
        error "Usage: dk env $project update <name> [new-compose-file]" $EXIT_USAGE
      fi

      local check_key="${project}:${env_name}"
      if [[ -z "${PROJECT_ENVS[$check_key]:-}" ]]; then
        error "Environment '${env_name}' not found for project '${project}'" $EXIT_NOT_FOUND
      fi

      # If no new file provided, prompt interactively
      if [[ -z "$env_file" ]]; then
        echo ""
        echo "  ${C_BOLD}Current path:${C_RESET} ${PROJECT_ENVS[$check_key]}"
        echo ""

        # Scan for compose files
        local compose_files
        compose_files=$(scan_compose_files "$dir")
        local scan_files=()
        if [[ -n "$compose_files" ]]; then
          while read -r f; do
            [[ -n "$f" ]] && scan_files+=("$f")
          done <<< "$compose_files"
        fi

        local scan_count=${#scan_files[@]}

        if [[ $scan_count -gt 0 ]]; then
          echo "  ${C_DIM}How would you like to choose?${C_RESET}"
          echo ""
          echo "  ${C_WHITE}1)${C_RESET}  Pick from scanned files"
          echo "  ${C_WHITE}2)${C_RESET}  Enter path manually"
          echo ""
          local method
          method=$(ask "  ${C_CYAN}?${C_RESET} Choice (1/2): ")

          if [[ "$method" == "1" ]]; then
            echo ""
            echo "  ${C_BOLD}Select new compose file:${C_RESET}"
            echo ""
            _checkbox_select "${scan_files[@]}"

            if [[ ${#CHECKBOX_RESULT[@]} -eq 0 ]]; then
              error "No file selected" $EXIT_USAGE
            fi
            # Use the first selected file
            env_file="${scan_files[${CHECKBOX_RESULT[1]}]}"
          else
            echo ""
            env_file=$(ask "  ${C_CYAN}?${C_RESET} New compose file path: ")
            [[ -z "$env_file" ]] && error "No path provided" $EXIT_USAGE
          fi
        else
          env_file=$(ask "  ${C_CYAN}?${C_RESET} New compose file path: ")
          [[ -z "$env_file" ]] && error "No path provided" $EXIT_USAGE
        fi
      fi

      # Validate compose file exists
      local resolved="$env_file"
      [[ "$resolved" != /* ]] && resolved="$dir/$resolved"
      if [[ ! -f "$resolved" ]]; then
        error "Compose file not found: $resolved" $EXIT_NOT_FOUND
      fi

      config_remove_env "$project" "$env_name"
      echo "${project}.env.${env_name}=${env_file}" >> "$CONFIG_FILE"
      log "Updated environment: ${C_CYAN}${env_name}${C_RESET} -> ${env_file}"
      ;;

    default)
      local env_name="${3:-}"

      if [[ -z "$env_name" ]]; then
        error "Usage: dk env $project default <name>" $EXIT_USAGE
      fi

      local check_key="${project}:${env_name}"
      if [[ -z "${PROJECT_ENVS[$check_key]:-}" ]]; then
        error "Environment '${env_name}' not found for project '${project}'" $EXIT_NOT_FOUND
      fi

      # Remove any existing .env.default line, then rename the target env
      # Strategy: we mark default by reordering (first env = default)
      # Simpler: just store a .default key
      config_remove_env "$project" "__default__"
      echo "${project}.env.__default__=${env_name}" >> "$CONFIG_FILE"

      # Reload to pick up the change (update in-memory)
      PROJECT_DEFAULT_ENV[$project]="$env_name"
      log "Default environment set to: ${C_CYAN}${env_name}${C_RESET}"
      ;;

    *)
      error "Unknown env action: $action (use: list, info, add, update, remove, default)" $EXIT_USAGE
      ;;
  esac
}

########################################
# FLAG PARSER
########################################

parse_flags() {

  local known_flags=(--force -f --purge -p --build -b --quiet -q --tail -t
                     --version -v --help -h --down -d --all --env -e)

  while [[ $# -gt 0 ]]; do

    case $1 in
      --force|-f)
        FORCE=true
        ;;
      --purge|-p)
        PURGE=true
        ;;
      --build|-b)
        BUILD=true
        ;;
      --quiet|-q)
        QUIET=true
        ;;
      --tail|-t)
        [[ $# -lt 2 ]] && error "--tail requires a number argument" $EXIT_USAGE
        TAIL="$2"
        shift
        ;;
      --down|-d)
        CLEAN_DOWN=true
        ;;
      --all)
        CLEAN_ALL=true
        ;;
      --env|-e)
        [[ $# -lt 2 ]] && error "--env requires an environment name" $EXIT_USAGE
        ENV_FLAG="$2"
        shift
        ;;
      --version|-v)
        echo "dk v${VERSION}"
        exit $EXIT_OK
        ;;
      --*)
        local is_known=false
        for flag in "${known_flags[@]}"; do
          [[ "$1" == "$flag" ]] && is_known=true && break
        done
        if [[ "$is_known" == false ]]; then
          error "Unknown flag: $1 (see 'dk help')" $EXIT_USAGE
        fi
        ;;
    esac

    shift
  done
}

########################################
# MAIN
########################################

main() {

  load_config

  [[ $# -lt 1 ]] && { cmd_help; exit $EXIT_OK; }

  parse_flags "$@"

  local action=$1

  if [[ "$action" == "help" || "$action" == "--help" || "$action" == "-h" ]]; then
    cmd_help
    exit $EXIT_OK
  fi

  if [[ "$action" == "--version" || "$action" == "-v" ]]; then
    echo "dk v${VERSION}"
    exit $EXIT_OK
  fi

  # Commands that don't require docker
  case "$action" in
    init)
      cmd_init
      exit $EXIT_OK
      ;;
    add)
      [[ $# -lt 2 ]] && error "Usage: dk add <name> [path]" $EXIT_USAGE
      cmd_add "$2" "${3:-}"
      exit $EXIT_OK
      ;;
    remove)
      [[ $# -lt 2 ]] && error "Usage: dk remove <name>" $EXIT_USAGE
      cmd_remove "$2"
      exit $EXIT_OK
      ;;
  esac

  # Docker required from here on
  check_dependencies

  # Commands that don't require a project
  case "$action" in
    list)
      cmd_list
      exit $EXIT_OK
      ;;
    status)
      cmd_status
      exit $EXIT_OK
      ;;
  esac

  [[ $# -lt 2 ]] && error "Project name required. Run 'dk help' for usage." $EXIT_USAGE

  local project=$2

  # env subcommand has its own validation
  if [[ "$action" == "env" ]]; then
    cmd_env "$project" "${3:-}" "${4:-}" "${5:-}"
    exit $EXIT_OK
  fi

  validate_project "$project"

  local dir="${PROJECTS[$project]}"

  validate_project_dir "$dir" "$project"

  case "$action" in
    up)
      cmd_up "$project" "$dir"
      ;;
    down)
      cmd_down "$project" "$dir"
      ;;
    stop)
      cmd_stop "$project" "$dir"
      ;;
    restart)
      cmd_restart "$project" "$dir"
      ;;
    build)
      cmd_build "$project" "$dir"
      ;;
    logs)
      local service=""
      if [[ $# -ge 3 && "${3:0:1}" != "-" ]]; then
        service="$3"
      fi
      cmd_logs "$project" "$dir" "$service"
      ;;
    ps)
      cmd_ps "$project" "$dir"
      ;;
    exec)
      if [[ $# -lt 4 ]]; then
        error "Usage: dk exec <project> <service> <command...>" $EXIT_USAGE
      fi
      local service=$3
      shift 3
      cmd_exec "$project" "$dir" "$service" "$@"
      ;;
    shell)
      if [[ $# -lt 3 ]]; then
        error "Usage: dk shell <project> <service>" $EXIT_USAGE
      fi
      cmd_shell "$project" "$dir" "$3"
      ;;
    pull)
      cmd_pull "$project" "$dir"
      ;;
    clean)
      cmd_clean "$project" "$dir"
      ;;
    *)
      error "Unknown command: $action (see 'dk help')" $EXIT_USAGE
      ;;
  esac
}

main "$@"
