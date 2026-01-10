## docker-ps formatter

Colorized, readable `docker ps` output.

### One-command install (Linux/macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/psss-docker/main/pss-docker.sh | sudo install -m 0755 /dev/stdin /usr/local/bin/docker-ps
```

Notes:
- Requires `sudo` rights to write into `/usr/local/bin`.
- Ensure Docker is installed and your user can run it (join the `docker` group on Linux if needed).

### Update

Run the same install command again; it overwrites the binary.

### Uninstall

```bash
sudo rm /usr/local/bin/docker-ps
```

### Usage

```bash
docker-ps
```

### Local install without network

```bash
chmod +x pss-docker.sh
sudo install -m 0755 pss-docker.sh /usr/local/bin/docker-ps
```
# pss-docker
