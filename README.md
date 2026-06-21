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
| Container name (header) | Yellow (`\033[93m`) |
| Labels (Image, Ports, …) | Cyan (`\033[96m`) |

### Template fields

Standard `docker ps` fields: `Names`, `Image`, `Ports`, `ID`, `Command`, `CreatedAt`, `RunningFor`, `State`, `Status`, `Size`, `Networks`.

Conditional fields (shown with flags):
- **Memory** (with `-m` / `-mi`): container memory usage (e.g. `1.2MB / 1.29GB`)
- **ImageTotal** (with `-mi`): total size of unique images used by filtered containers

## Installation

### One-command install (Linux/macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/mtvy/pss-docker/main/pss-docker.sh | sudo tee /usr/local/bin/d-ps >/dev/null && sudo chmod 0755 /usr/local/bin/d-ps
```

> **Why `tee` and not `cat >`?** BSD `install` (macOS) cannot read from `/dev/stdin`; `tee` works on both Linux and macOS.

### Local install (no network)

```bash
chmod +x pss-docker.sh
sudo install -m 0755 pss-docker.sh /usr/local/bin/d-ps
```

### Notes

- Requires `sudo` to write into `/usr/local/bin`.
- Ensure Docker is installed and your user can run it (on Linux, add yourself to the `docker` group if needed).
- The script installs as `d-ps` on `PATH`.

## Usage

### `d-ps`

List all running containers with card-style formatting:

```bash
d-ps
```

### `d-ps -f <filter>`

Filter containers by partial name (case-insensitive):

```bash
d-ps -f postgres
```

This will match containers like `db-postgres-1`, `postgres-4`, etc.

### `d-ps -a`

Show all containers (including stopped ones), equivalent to `docker ps -a`:

```bash
d-ps -a
```

### Combined flags

```bash
d-ps -a -f web
```

List all containers (including stopped) whose names contain "web".

### `d-ps -m`

Show memory usage for each container:

```bash
d-ps -m
```

Output includes a `Memory` field showing used/limit (e.g. `1.2MB / 1.29GB`).

### `d-ps -mi`

Show memory usage and image sizes:

```bash
d-ps -mi
```

Output includes `Memory` field and a total image size line below each card listing all unique images used by the filtered containers.

### All flags combined

```bash
d-ps -mi -f web
```

Filter by name, show memory and image sizes for matching containers only.

## Update

Re-run the install command; it overwrites the installed binary.

## Uninstall

```bash
sudo rm /usr/local/bin/d-ps
```

## Requirements

- **Bash** 3+ (macOS ships with Bash 3; Linux typically has Bash 4+)
- **Docker CLI** installed and available on `PATH`
- A terminal that supports **ANSI color escape codes** (all modern terminals do)
