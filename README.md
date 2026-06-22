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
- Other `docker ps` flags (beyond `-a`, `-f`, `-m`, `-mi`, `-h`, `--help`) are not supported.
