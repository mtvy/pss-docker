# pss-docker

Colorized, card-style `docker ps` output — a drop-in replacement for the default flat table.

<img width="539" height="359" alt="Снимок экрана 2026-01-10 в 23 05 47" src="https://github.com/user-attachments/assets/1fc09646-d9c2-4ed0-bdd9-5616111c2191" />

## How it works

`pss-docker.sh` is a Bash wrapper around `docker ps --format` with a custom Go template:

1. **Dependency check** — verifies `docker` is on `PATH` (exits with error if missing).
2. **`docker ps` call** — runs `docker ps --format` with a Go template that embeds ANSI escape sequences for color and box-drawing characters (`┌ └ │`) for card-style framing.

Each running container is rendered as a vertical card:

```
┌container-name
│     [Image]      nginx:latest
│     [Ports]      0.0.0.0:80->80/tcp
│     [ID]         abc123def456
│     [Command]    nginx -g daemon off;
│     [CreatedAt]  2 hours ago
│     [RunningFor] 2 hours
│     [State]      running
│     [Status]     Up 2 hours
│     [Size]       42.7MB (virtual)
│     [Names]      web
│     [Networks]   bridge
└─────────────────
```

### Color mapping

| Field      | Color            |
|------------|------------------|
| Container name (header) | Green / Red / Yellow by state |
| Labels (Image, Ports, …) | Cyan (`\033[36m`) |

### Template fields

The Go template exposes all standard `docker ps` fields: `Names`, `Image`, `Ports`, `ID`, `Command`, `CreatedAt`, `RunningFor`, `State`, `Status`, `Size`, `Networks`.

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

List all running containers with card-style formatting:

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

### `dps -l`

Compact card with only the container name, ports (if any), and status:

```bash
dps -l
```

Example output:

```
┌webserver-1
│     [Ports]      0.0.0.0:80->80/tcp
│     [Status]     Up 2 hours
└─────────────────
```

The `-l` flag does not disable other extra fields — combine with `-m`, `-mi`, or `-ls` to show memory, image info, or compose directory below the compact card.

```bash
dps -l -m
dps -l -ls -mi
```

### `dps -ls`

Show the docker compose project directory below each card (for containers started via Docker Compose):

```bash
dps -ls
```

Example output:

```
┌paperless-webserver-1
│     [Image]      ghcr.io/paperless-ngx/paperless-ngx:dev
│     ...
└─────────────────
  ↳ [Source]  /home/user/projects/paperless
```

Only shown when the container has the `com.docker.compose.project.working_dir` label (Compose V2). Plain `docker run` containers are skipped.

### `dps -d`

Show a dependency graph for each Docker Compose project after the cards (from `depends_on` labels):

```bash
dps -a -d
```

Example output:

```
┌infogram-frontend
│     ...
└─────────────────

── infogram dependencies ──
  elasticsearch  (infogram-es)
      ↓
  frontend  (infogram-frontend)
```

Use `-a` to include stopped containers in the graph. Combine with other flags:

```bash
dps -a -d -f infogram
dps -l -d
```

### `dps -m`

Show container RAM usage below each card (from `docker stats`):

```bash
dps -m
```

Stopped containers show `-` for memory.

### `dps -mi`

Show RAM usage plus image name and disk size below each card:

```bash
dps -mi
```

Example output:

```
┌paperless-webserver-1
│     [Image]      ghcr.io/paperless-ngx/paperless-ngx:dev
│     ...
└─────────────────
  ↳ [Memory]  512MiB / 2GiB
  ↳ [Image]  ghcr.io/paperless-ngx/paperless-ngx:dev  (1.29GB)
```

Combine with other flags:

```bash
dps -a -f web -mi
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

- `-m` / `-mi` require an extra `docker stats` call; memory is only available for running containers.
- `-mi` adds a `docker images` lookup for image disk sizes.
- `-ls` adds a batch `docker inspect` call to read compose project labels.
- `-ls` only works for containers started with Docker Compose V2 (`com.docker.compose.project.working_dir` label).
- `-d` builds dependency graphs from the `com.docker.compose.depends_on` label (Compose V2); use `-a` for stopped services.
- Other `docker ps` flags (beyond `-a`, `-f`, `-l`, `-ls`, `-d`, `-m`, `-mi`, `-h`, `--help`) are not supported.
