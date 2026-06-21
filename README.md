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

|| Field      | Color            |
|------------|------------------|
|| Container name (header) | Yellow (`\033[93m`) |
|| Labels (Image, Ports, …) | Cyan (`\033[96m`) |

### Template fields

The Go template exposes all standard `docker ps` fields: `Names`, `Image`, `Ports`, `ID`, `Command`, `CreatedAt`, `RunningFor`, `State`, `Status`, `Size`, `Networks`.

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

### Symlink for `dc-ps`

After installing `d-ps`, create a symlink to enable `dc-ps` (docker compose support):

```bash
sudo ln -sf /usr/local/bin/d-ps /usr/local/bin/dc-ps
```

### Notes

- Requires `sudo` to write into `/usr/local/bin`.
- Ensure Docker is installed and your user can run it (on Linux, add yourself to the `docker` group if needed).
- The script installs as `d-ps` on `PATH`.
- `dc-ps` is available as a symlink to the same script.

## Usage

### `d-ps`

List all running containers with card-style formatting:

```bash
d-ps
```

### `d-ps <partial>`

Filter containers by partial name. Shows only containers whose names contain the given substring:

```bash
d-ps postgres
```

This will match containers like `db-postgres-1`, `postgres-4`, etc.

### `dc-ps`

List all containers from docker compose projects (equivalent to `docker compose ps -a`):

```bash
dc-ps
```

## Update

Re-run the install command; it overwrites the installed binary.

## Uninstall

```bash
sudo rm /usr/local/bin/d-ps
sudo rm -f /usr/local/bin/dc-ps
```

## Requirements

- **Bash** 3+ (macOS ships with Bash 3; Linux typically has Bash 4+)
- **Docker CLI** installed and available on `PATH`
- **Docker Compose** plugin (for `dc-ps`)
- A terminal that supports **ANSI color escape codes** (all modern terminals do)

## Limitations

- `d-ps` accepts at most one argument (partial name filter). Other `docker ps` flags are not supported.
- Shows only running containers (uses `docker ps`, not `docker ps -a`). Use `dc-ps` to list all compose containers.
