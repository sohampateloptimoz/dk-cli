# Docker Kommander (`dk`) - Complete User Guide

> Version 2.0.0

**Docker Kommander** — a safe, opinionated CLI wrapper around `docker compose` for managing multiple local projects with multi-environment support from anywhere in your terminal.

---

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
- [Configuration](#configuration)
- [Environment System](#environment-system)
- [Commands Reference](#commands-reference)
  - [up](#up---start-containers)
  - [stop](#stop---stop-containers)
  - [down](#down---stop-and-remove-containers)
  - [restart](#restart---restart-containers)
  - [build](#build---rebuild-images)
  - [logs](#logs---stream-logs)
  - [ps](#ps---container-status)
  - [exec](#exec---run-a-command-in-a-container)
  - [shell](#shell---open-a-shell-in-a-container)
  - [pull](#pull---pull-latest-images)
  - [clean](#clean---interactive-cleanup)
  - [add](#add---register-a-project)
  - [remove](#remove---unregister-a-project)
  - [env](#env---manage-environments)
  - [status](#status---all-projects-overview)
  - [list](#list---list-projects)
  - [init](#init---create-config-file)
  - [help](#help---show-help)
- [Flags Reference](#flags-reference)
- [Exit Codes](#exit-codes)
- [Workflows](#workflows)
- [Safety Guarantees](#safety-guarantees)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Dependency          | Minimum Version |
| ------------------- | --------------- |
| **Zsh**             | 5.0+            |
| **Docker**          | 20.10+          |
| **Docker Compose**  | v2 (plugin)     |

The script checks for these at startup and exits with a clear error if missing.

---

## Installation

### 1. Place the script

```bash
# Symlink d.sh to your local bin
mkdir -p ~/.local/bin
ln -sf /path/to/d.sh ~/.local/bin/dk

# Make sure ~/.local/bin is in your PATH
# Add to ~/.zshrc if not already there:
export PATH="$HOME/.local/bin:$PATH"
```

### 2. Make it executable

```bash
chmod +x /path/to/d.sh
```

### 3. Enable tab completion (optional)

```bash
# Symlink the completion file (stays in sync with the repo)
mkdir -p ~/.zsh/completions
ln -sf /path/to/dk-cli/_dk ~/.zsh/completions/_dk

# Add to ~/.zshrc (before compinit):
fpath=(~/.zsh/completions $fpath)
autoload -Uz compinit && compinit
```

Restart your shell or run `exec zsh` to activate.

**What it completes:**

| Context | Completions |
| ------- | ----------- |
| `dk <TAB>` | All commands with descriptions |
| `dk up <TAB>` | Registered project names |
| `dk logs myapp <TAB>` | Services from the project's compose file |
| `dk env myapp <TAB>` | Environment subcommands (`list`, `add`, `info`, etc.) |
| `dk env myapp info <TAB>` | Configured environment names |
| `dk up --<TAB>` | Context-aware flags (`--build`, `--env`, etc.) |

### 4. Verify it works

```bash
dk --version
# Output: dk v2.0.0

dk help
# Shows the full help page

# Test tab completion
dk <TAB>        # shows all commands
dk up <TAB>     # shows registered projects
dk logs backend <TAB>  # shows services from compose file
```

---

## Quick Start

```bash
# 1. Register a project (smart scanner auto-detects compose files)
dk add ~/workspace/backend

# 2. Start a project
dk up backend

# 3. Check what's running
dk status

# 4. View logs
dk logs backend

# 5. Start with a specific environment
dk up backend --env staging

# 6. Stop when done
dk stop backend
```

---

## Configuration

### Config file location

```
~/.config/dk/projects.conf
```

If `XDG_CONFIG_HOME` is set, it uses `$XDG_CONFIG_HOME/dk/projects.conf` instead.

### Config file format

```conf
# Project path
backend=/home/user/workspace/backend

# Environment definitions (dot notation)
backend.env.default=docker-compose.yml
backend.env.dev=docker-compose.dev.yml
backend.env.staging=docker/compose.staging.yml
backend.env.prod=deployments/production.yml
backend.env.__default__=dev

analytics=/home/user/workspace/analytics
analytics.env.default=docker-compose.yml
```

### Format rules

- `name=path` — registers a project
- `name.env.<envname>=<compose-file>` — maps an environment to a compose file (path relative to project root)
- `name.env.__default__=<envname>` — sets which environment is used by default
- Lines starting with `#` are comments
- Empty lines are ignored
- `~` is expanded to your home directory

> **Note:** You rarely need to edit this file manually. Use `dk add` and `dk env` commands instead.

---

## Environment System

Projects can have multiple compose files mapped to named environments (dev, staging, prod, etc.). This lets you switch between configurations without editing files.

### How environments work

1. **Each project can have multiple environments**, each pointing to a different compose file
2. **One environment is the default** — used when you run commands without `--env`
3. **The `--env` flag** overrides the default for any command
4. **If no environments are configured**, dk auto-detects the compose file in the project root

### Environment resolution order

When you run a command, dk resolves the compose file in this priority:

1. `--env <name>` flag (if provided)
2. Project's default environment (`__default__`)
3. First configured environment
4. Auto-detect from project root (`docker-compose.yml`, `compose.yml`, etc.)

### Quick examples

```bash
# Use default environment
dk up myapp

# Use a specific environment
dk up myapp --env staging
dk up myapp -e prod

# Manage environments
dk env myapp                        # list all envs
dk env myapp info dev               # detailed info for an env
dk env myapp add staging docker/compose.staging.yml
dk env myapp update dev new-compose.dev.yml
dk env myapp remove old-env
dk env myapp default staging        # set default env
```

---

## Commands Reference

### `up` - Start containers

Starts all services defined in the project's compose file in detached mode.

```bash
dk up <project>
dk up <project> --build        # rebuild images first
dk up <project> -b             # short form
dk up <project> --env staging  # use staging environment
```

**What it runs:**
- `docker compose -f <compose-file> up -d`
- `docker compose -f <compose-file> up -d --build` (with `--build` flag)

**When to use `--build`:**
- After changing a Dockerfile
- After modifying code that gets copied into the image
- After changing `package.json` or other dependency files

---

### `stop` - Stop containers

Stops running containers **without removing them**. The containers, networks, and volumes are all preserved. You can start them again with `dk up`.

```bash
dk stop <project>
dk stop <project> --env dev
```

**What it runs:** `docker compose stop`

**Use this when:**
- You want to free up CPU/memory temporarily
- You plan to start the same containers again soon
- You don't want to recreate containers from scratch

---

### `down` - Stop and remove containers

Stops containers **and removes them** along with their networks. Volumes are preserved by default.

```bash
dk down <project>            # keeps volumes (database data safe)
dk down <project> --purge    # also removes volumes (database data DELETED)
dk down <project> -p -f      # purge + skip confirmation
```

**What it runs:**
- `docker compose down --remove-orphans`
- `docker compose down --remove-orphans --volumes` (with `--purge`)

**`stop` vs `down` — when to use which:**

| Scenario                          | Use        |
| --------------------------------- | ---------- |
| Quick break, resuming soon        | `stop`     |
| Done for the day                  | `down`     |
| Troubleshooting stale state       | `down`     |
| Fresh database / clean slate      | `down -p`  |
| CI/CD pipeline cleanup            | `down -p -f` |

---

### `restart` - Restart containers

Restarts all containers without removing them. Useful after config changes that don't require a rebuild.

```bash
dk restart <project>
```

**What it runs:** `docker compose restart`

---

### `build` - Rebuild images

Rebuilds Docker images without starting containers. Useful when you want to pre-build before starting.

```bash
dk build <project>
dk build <project> --env prod
```

**What it runs:** `docker compose build`

---

### `logs` - Stream logs

Streams live logs from all services or a specific service.

```bash
dk logs <project>                    # all services, stream live
dk logs <project> api                # only the "api" service
dk logs <project> --tail 100         # last 100 lines, then stream
dk logs <project> api --tail 50      # last 50 lines of "api" service
dk logs <project> -t 200             # short form for --tail
```

**What it runs:** `docker compose logs -f [--tail N] [service]`

**Tips:**
- Press `Ctrl+C` to stop streaming
- The service name must match the service name in your compose file
- Without `--tail`, it streams from the beginning of the log buffer

---

### `ps` - Container status

Shows the status of all containers in a project.

```bash
dk ps <project>
```

**What it runs:** `docker compose ps`

**Output includes:** container name, command, state, ports.

---

### `exec` - Run a command in a container

Executes a command inside a **running** container. The container must already be started with `dk up`.

```bash
dk exec <project> <service> <command...>
```

**Examples:**

```bash
# Run database migrations
dk exec backend api yarn migrate

# Check Node.js version inside container
dk exec backend api node --version

# Run psql in the database container
dk exec backend db psql -U postgres

# Install a new package
dk exec backend api yarn add lodash
```

---

### `shell` - Open a shell in a container

Opens an interactive `/bin/sh` shell inside a **running** container.

```bash
dk shell <project> <service>
```

**Examples:**

```bash
dk shell backend api
dk shell backend db
```

**Note:** Uses `/bin/sh` which is available in all containers (including Alpine-based). If you need bash, use `dk exec <project> <service> /bin/bash`.

---

### `pull` - Pull latest images

Pulls the latest versions of all images defined in the project's compose file.

```bash
dk pull <project>
```

**What it runs:** `docker compose pull`

---

### `clean` - Interactive cleanup

Interactively removes build artifacts, Docker volumes, and Docker images associated with a project. Shows sizes and lets you select what to remove.

```bash
dk clean <project>
dk clean <project> --force    # skip confirmations
```

**What it detects:**

| Category | Items |
| -------- | ----- |
| **Build artifacts** | `node_modules/`, `dist/`, `build/`, `.next/`, `.cache/` |
| **Docker volumes** | Volumes associated with the project's compose file |
| **Docker images** | Images built by the project's compose file |

**Interactive selection:**

When you run `dk clean`, it scans for all removable items and presents a numbered list:

```
  Artifacts found:
  1)  node_modules/    (245M)
  2)  dist/            (12M)
  3)  .cache/          (3M)

  Select items to remove (a=all, n=none, 1,3=specific):
```

**Options:**
- `a` — remove all items
- `n` — remove nothing
- `1,3` — remove specific items by number

**Safety:**
- Running containers are detected and you're warned before cleaning
- `--force` skips confirmations but still shows what's being removed
- Volumes require `--purge` flag to be included

---

### `add` - Register a project

Adds a new project with smart compose file detection. The scanner automatically finds compose files across your project.

```bash
dk add <path>                  # auto-derive name from directory
dk add <name> <path>           # explicit name
dk add <name>                  # use current directory
```

**Examples:**

```bash
# Smart add — name derived from path
dk add ~/workspace/backend
# → Registers as "backend"

# Explicit name
dk add myapp ~/workspace/my-application

# From current directory
cd ~/workspace/frontend && dk add frontend
```

#### Smart compose file scanner

When adding a project, dk scans for compose files in 3 phases:

| Phase | What it scans | Example matches |
| ----- | ------------- | --------------- |
| **1. Root standard** | Standard compose filenames in project root | `docker-compose.yml`, `docker-compose.dev.yml`, `compose.yaml` |
| **2. Common subdirs** | `.yml`/`.yaml` files in known directories with `services:` keyword | `docker/compose.staging.yml`, `deployments/production.yml` |
| **3. Deep scan** | All `.yml`/`.yaml` files up to 3 levels deep with `services:` keyword | `services/api/docker-compose.yml`, `infra/monitoring.yml` |

**Skipped directories:** `node_modules`, `.git`, `vendor`, `.cache`

**Non-compose files** (YAML files without `services:` keyword) are automatically excluded.

#### Add flow

**Single compose file found:**
```
Scanning for compose files...

  1) docker-compose.yml

  ✔  default -> docker-compose.yml

  ? Add other compose files as environments? (y/N):
```
The single file is auto-selected as default. Say `N` to finish, `Y` to add more.

**Multiple compose files found:**
```
Scanning for compose files...

  1) docker-compose.yml
  2) docker-compose.dev.yml
  3) docker/compose.staging.yml
  4) deployments/production.yml

  Which file should be the default environment?
  Enter number (1-4), 'm' for manual, or 's' to skip:

  ? Default: 1
  ✔  default -> docker-compose.yml

  ? Add other compose files as environments? (y/N): y

  How would you like to add environments?

  1)  Pick from scanned files
  2)  Enter paths manually
  3)  Both

  ? Choice (1/2/3):
```

**Interactive checkbox selection (option 1):**

When picking from scanned files, an interactive checkbox selector appears:

```
  Select compose files to add as environments:

  ❯  ○  docker-compose.dev.yml
     ○  docker/compose.staging.yml
     ○  deployments/production.yml

  ↑/↓ navigate  ·  space toggle  ·  a all  ·  enter confirm
```

Use arrow keys to move, spacebar to toggle `●/○`, `a` to select all, enter to confirm. Then name each selected file:

```
  ●  docker-compose.dev.yml
  ●  deployments/production.yml

  docker-compose.dev.yml -> env name: dev
  ✔  dev -> docker-compose.dev.yml
  deployments/production.yml -> env name: prod
  ✔  prod -> deployments/production.yml
```

#### Re-running add on existing project

If a project already has a default environment, `dk add <project>` detects it, shows existing envs, and jumps straight to adding more — no need to reconfigure the default:

```
Project: backend (/home/user/workspace/backend)
──────────────────────────────────────

  Current environments:
  ✔  default -> docker-compose.yml

  Scanning for compose files...

  Unassigned compose files:
  1)  docker-compose.dev.yml
  2)  docker/compose.staging.yml

  How would you like to add environments?
  ...
```

**Name rules:** Only letters, numbers, hyphens (`-`), and underscores (`_`) are allowed.

---

### `remove` - Unregister a project

Removes a project entry and all its environments from the config file. This does **NOT** delete any files, containers, or volumes.

```bash
dk remove <name>
dk remove <name> --force    # skip confirmation
```

**What happens:**
- Shows the project path and environment count
- Asks for confirmation
- Removes the project and all `name.env.*` lines from the config

---

### `env` - Manage environments

Manage compose file environments for a project.

```bash
dk env <project> [action] [args...]
```

#### `env list` (default)

Lists all environments for a project with status indicators.

```bash
dk env myapp
dk env myapp list
```

**Output:**
```
Environments: myapp
──────────────────────────────────────

  ✔  default (default)
     docker-compose.yml

  ✔  dev
     docker-compose.dev.yml

  ✖  staging
     docker/compose.staging.yml
```

- `✔` — compose file exists
- `✖` — compose file missing
- `(default)` — this env is used when no `--env` flag is specified

#### `env info`

Shows detailed information about a specific environment.

```bash
dk env myapp info dev
```

**Output:**
```
Environment: dev
──────────────────────────────────────

  Project:      myapp
  Project dir:  /home/user/workspace/myapp
  Compose file: docker-compose.dev.yml
  Full path:    /home/user/workspace/myapp/docker-compose.dev.yml
  File exists:  Yes
  File size:    428B
  Default:      No
  Services:     app, db, redis, mailhog
```

#### `env add`

Adds a new environment.

```bash
dk env myapp add staging docker/compose.staging.yml
```

- Validates the compose file exists
- If the env name already exists, asks to confirm overwrite

#### `env update`

Updates the compose file path for an existing environment.

```bash
# Inline
dk env myapp update dev docker-compose.dev-v2.yml

# Interactive (prompts with options)
dk env myapp update dev
```

When run interactively, you get two options:

```
  Current path: docker-compose.dev.yml

  How would you like to choose?

  1)  Pick from scanned files
  2)  Enter path manually

  ? Choice (1/2):
```

Option 1 opens the interactive checkbox selector to pick from scanned compose files.

#### `env remove`

Removes an environment.

```bash
dk env myapp remove staging
dk env myapp rm staging        # alias
```

#### `env default`

Sets which environment is used by default.

```bash
dk env myapp default dev
```

After this, `dk up myapp` uses the `dev` compose file. Override with `dk up myapp --env prod`.

---

### `status` - All projects overview

Shows the running state of **all** registered projects at a glance.

```bash
dk status
```

**Output:**
```
Project Status Overview

  ● backend      running (3)
  ○ analytics    stopped
  ✖ frontend     (directory missing)
```

**Symbols:**
- `●` Green = running (with container count)
- `○` Dim = stopped
- `✖` Red = directory missing or error

---

### `list` - List projects

Shows all registered projects with their paths, running state, and configured environments.

```bash
dk list
```

**Output:**
```
Registered Docker Projects
──────────────────────────────────────

  ● backend
    ~/workspace/backend
    running (3) · envs: default, dev, staging

  ○ analytics
    ~/workspace/analytics
    stopped · envs: default

  Config: ~/.config/dk/projects.conf
```

---

### `init` - Create config file

Generates a default config file at `~/.config/dk/projects.conf`.

```bash
dk init
```

---

### `help` - Show help

Displays the built-in help page.

```bash
dk help
dk --help
dk -h
dk          # no arguments also shows help
```

---

## Flags Reference

Flags can be placed anywhere in the command (before or after the project name).

| Flag              | Short | Used With    | Description                              |
| ----------------- | ----- | ------------ | ---------------------------------------- |
| `--build`         | `-b`  | `up`         | Rebuild images before starting           |
| `--purge`         | `-p`  | `down`       | Remove volumes (deletes database data)   |
| `--force`         | `-f`  | any          | Skip all confirmation prompts            |
| `--quiet`         | `-q`  | any          | Suppress informational log messages      |
| `--tail <N>`      | `-t`  | `logs`       | Show last N lines then stream            |
| `--env <name>`    | `-e`  | any command  | Use a specific environment               |
| `--version`       | `-v`  | global       | Print version and exit                   |
| `--help`          | `-h`  | global       | Show help and exit                       |

**Flag placement:** all of these are equivalent:

```bash
dk up backend --build
dk up --build backend
dk --build up backend
```

**Combining flags:**

```bash
dk down backend --purge --force
dk down backend -p -f
dk up backend --build --env staging
dk up backend -b -e prod
```

---

## Exit Codes

| Code | Constant         | Meaning                                     |
| ---- | ---------------- | ------------------------------------------- |
| `0`  | `EXIT_OK`        | Success                                     |
| `1`  | `EXIT_GENERAL`   | General / unexpected error                  |
| `2`  | `EXIT_USAGE`     | Invalid usage (wrong args, unknown command)  |
| `3`  | `EXIT_NOT_FOUND` | Project or directory not found              |
| `4`  | `EXIT_DEPENDENCY`| Docker or Docker Compose not installed       |
| `130`| *(signal)*       | Interrupted by Ctrl+C                       |

---

## Workflows

### Daily development workflow

```bash
# Morning: start your project
dk up backend

# Check everything is running
dk ps backend

# Stream logs while you work
dk logs backend api --tail 50

# End of day: stop (keep containers for tomorrow)
dk stop backend
```

### Multi-environment workflow

```bash
# Development (default)
dk up myapp

# Test with staging config
dk up myapp --env staging

# Check which envs are available
dk env myapp

# Detailed info about an env
dk env myapp info staging

# Switch default to dev
dk env myapp default dev
```

### Adding a new project

```bash
# Smart add — scans and sets up environments interactively
dk add ~/workspace/my-new-project

# Later, add more environments
dk add my-new-project
# → Detects existing default, jumps to adding more envs

# Or add manually
dk env my-new-project add staging docker/compose.staging.yml
```

### Fresh start / debugging workflow

```bash
# Stop and remove everything
dk down backend --purge --force

# Clean local artifacts interactively
dk clean backend

# Rebuild from scratch
dk up backend --build
```

### Running database migrations

```bash
# Make sure containers are running
dk up backend

# Run the migration command inside the api service
dk exec backend api yarn migrate

# Or open a shell to run multiple commands
dk shell backend api
```

### Updating images

```bash
# Pull latest images
dk pull backend

# Restart with new images
dk down backend
dk up backend

# Or in one step: rebuild + start
dk up backend --build
```

### CI/CD pipeline usage

```bash
#!/bin/bash
dk up backend --build --quiet --force --env prod

# Run tests
dk exec backend api yarn test
TEST_EXIT=$?

# Always clean up
dk down backend --purge --force --quiet
exit $TEST_EXIT
```

---

## Safety Guarantees

1. **No global operations** — dk will NEVER run `docker system prune` or `docker volume prune`. Every action is scoped to a single project.

2. **Volumes preserved by default** — `dk down` keeps your database data. You must explicitly pass `--purge` to delete volumes.

3. **Confirmation prompts** — Destructive operations (purge, clean, remove) always ask for confirmation. Use `--force` only when you're sure.

4. **Project isolation** — Each command operates only on the specified project's directory and compose file. It cannot affect other projects.

5. **Environment-aware** — All docker commands automatically use the correct compose file based on the active environment.

6. **Clean interrupts** — Pressing `Ctrl+C` exits gracefully with a clear message (exit code 130).

7. **Color-safe output** — Colors are only used when outputting to a terminal. Piping to a file or another command produces clean, parseable text.

---

## Troubleshooting

### "Docker not installed"
Install Docker Desktop or Docker Engine. Verify with `docker --version`.

### "Docker Compose v2 required"
The script uses `docker compose` (v2 plugin), not the old `docker-compose` (v1). Upgrade Docker Desktop or install the compose plugin.

### "Unknown project: xyz"
The project isn't registered. Run `dk list` to see available projects, or `dk add <path>` to register.

### "Project directory not found"
The path in your config doesn't exist. Check with `dk list` and re-add with `dk add`.

### "No compose file found"
The project directory exists but dk couldn't find a compose file. Either:
- Add one to the project root (`docker-compose.yml`)
- Register a custom path: `dk env myproject add default /path/to/compose.yml`

### "Environment not found"
The specified `--env` name doesn't exist. Run `dk env <project>` to see available environments.

### exec/shell says "no container found"
The containers must be running first. Run `dk up <project>` before using `exec` or `shell`.

### Colors look weird
If your terminal doesn't support ANSI colors, pipe through `cat` to strip them: `dk help | cat`.

### Checkbox selector not working
The interactive checkbox requires a TTY. It won't work when piped or in non-interactive shells. Use the CLI flags directly in scripts (e.g., `dk env myapp add staging compose.staging.yml`).
