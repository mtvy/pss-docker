# pss-docker

Colorized, card-style `docker ps` output — a readable alternative to the default flat table.

By default shows a **compact** list, with Docker Compose containers **grouped by project**.

<img width="539" height="359" alt="Снимок экрана 2026-01-10 в 23 05 47" src="https://github.com/user-attachments/assets/1fc09646-d9c2-4ed0-bdd9-5616111c2191" />

## How it works

`pss-docker.sh` is a Bash wrapper around `docker ps` plus a batch `docker inspect` for Compose labels:

1. **Dependency check** — verifies `docker` is on `PATH` (exits with error if missing).
2. **`docker ps` call** — collects container fields.
3. **`docker inspect`** — reads Compose project/service labels to group related containers.
4. **Render** — compact lines (default) or full cards (`-v`), grouped under project headers.

Default compact output for a Compose project:

```
── paperless ──
  webserver  (paperless-webserver-1)  0.0.0.0:8000->8000/tcp  Up 2 hours
  db         (paperless-db-1)         -                       Up 2 hours
```

Non-Compose containers (`docker run`, etc.) stay as individual compact cards:

```
┌redis
│     [Ports]      0.0.0.0:6379->6379/tcp
│     [Status]     Up 2 hours
└─────────────────
```

Full cards (`-v`) keep the previous vertical layout, still under project headers when applicable:

```
── paperless ──
┌paperless-webserver-1
│     [Image]      ghcr.io/paperless-ngx/paperless-ngx:dev
│     [Ports]      0.0.0.0:8000->8000/tcp
│     [ID]         abc123def456
│     [Command]    …
│     [CreatedAt]  2 hours ago
│     [RunningFor] 2 hours
│     [State]      running
│     [Status]     Up 2 hours
│     [Size]       42.7MB (virtual)
│     [Names]      paperless-webserver-1
│     [Networks]   paperless_default
└─────────────────
```

### Color mapping

| Field      | Color            |
|------------|------------------|
| Container / service name | Green / Red / Yellow by state |
| Labels (Image, Ports, …) and project headers | Cyan (`\033[36m`) |

### Template fields

Uses standard `docker ps` fields: `Names`, `Image`, `Ports`, `ID`, `Command`, `CreatedAt`, `RunningFor`, `State`, `Status`, `Size`, `Networks`. Compose grouping uses `com.docker.compose.project` and `com.docker.compose.service` labels.

## Installation

### One-command install (Linux/macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/mtvy/pss-docker/main/pss-docker.sh | sudo tee /usr/local/bin/dps >/dev/null && sudo chmod 0755 /usr/local/bin/dps
```

> **Why `tee` and not `cat >`?** BSD `install` (macOS) cannot read from `/dev/stdin`; `tee` works on both Linux and macOS.

### Local install (no network)

```bash
chmod +x pss-docker.sh
sudo install -m 0755 pss-docker.sh /usr/local/bin/dps
```

### Notes

- Requires `sudo` to write into `/usr/local/bin`.
- Ensure Docker is installed and your user can run it (on Linux, add yourself to the `docker` group if needed).
- The script installs as `dps` on `PATH`.

## Usage

Show help:

```bash
dps -h
dps --help
```

### `dps`

Compact list of running containers, grouped by Docker Compose project:

```bash
dps
```

### `dps -f <filter>`

Filter containers by partial name (case-insensitive):

```bash
dps -f postgres
```

This will match containers like `db-postgres-1`, `postgres-4`, etc.

### `dps -a`

Show all containers (including stopped ones), equivalent to `docker ps -a`:

```bash
dps -a
```

### Combined flags

```bash
dps -a -f web
```

List all containers (including stopped) whose names contain "web".

### `dps -v`

Full cards (Image, Ports, ID, Command, …). Compose containers remain grouped under a project header:

```bash
dps -v
```

### `dps -l`

Accepted for compatibility; compact output is already the default.

```bash
dps -l
```

### `dps -ls`

Show the docker compose project directory below each entry (for containers started via Docker Compose):

```bash
dps -ls
```

Example output:

```
── paperless ──
  webserver  (paperless-webserver-1)  0.0.0.0:8000->8000/tcp  Up 2 hours
  ↳ [Source]  /home/user/projects/paperless
```

Only shown when the container has the `com.docker.compose.project.working_dir` label (Compose V2). Plain `docker run` containers are skipped.

### `dps -d`

Show a dependency graph for each Docker Compose project after the list (from `depends_on` labels):

```bash
dps -a -d
```

Example output:

```
── infogram ──
  frontend  (infogram-frontend)  …  Up 2 hours

── infogram dependencies ──
  elasticsearch  (infogram-es)
      ↓
  frontend  (infogram-frontend)
```

Use `-a` to include stopped containers in the graph. Combine with other flags:

```bash
dps -a -d -f infogram
dps -d
```

### `dps -m`

Show container RAM usage below each entry (from `docker stats`):

```bash
dps -m
```

Stopped containers show `-` for memory.

### `dps -mi`

Show RAM usage plus image name and disk size below each entry:

```bash
dps -mi
```

Example output:

```
── paperless ──
  webserver  (paperless-webserver-1)  0.0.0.0:8000->8000/tcp  Up 2 hours
  ↳ [Memory]  512MiB / 2GiB
  ↳ [Image]  ghcr.io/paperless-ngx/paperless-ngx:dev  (1.29GB)
```

Combine with other flags:

```bash
dps -a -f web -mi
dps -v -mi
```

## Update

Re-run the install command; it overwrites the installed binary.

## Uninstall

```bash
sudo rm /usr/local/bin/dps
```

## Requirements

- **Bash** 3+ (macOS ships with Bash 3; Linux typically has Bash 4+)
- **Docker CLI** installed and available on `PATH`
- A terminal that supports **ANSI color escape codes** (all modern terminals do)

## Limitations

- Default output always batch-inspects containers to resolve Compose project labels (needed for grouping).
- `-m` / `-mi` require an extra `docker stats` call; memory is only available for running containers.
- `-mi` adds a `docker images` lookup for image disk sizes.
- `-ls` only works for containers started with Docker Compose V2 (`com.docker.compose.project.working_dir` label).
- `-d` builds dependency graphs from the `com.docker.compose.depends_on` label (Compose V2); use `-a` for stopped services.
- Other `docker ps` flags (beyond `-a`, `-f`, `-l`, `-v`, `-ls`, `-d`, `-m`, `-mi`, `-h`, `--help`) are not supported.
