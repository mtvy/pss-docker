# pss-docker

## Usage
```bash
git clone https://github.com/mtvy/pss-docker.git
cd pss-docker
sh ./pss-docker.sh
```

## Example
```bash
┌prometheus
│     [Image]      prom/prometheus:latest
│     [Ports]      0.0.0.0:9090->9090/tcp, :::9090->9090/tcp
│     [ID]         772471bbcd91
│     [Command]    "/bin/prometheus --c…"
│     [CreatedAt]  2023-03-10 19:54:08 +0000 UTC
│     [RunningFor] About an hour ago
│     [State]      running
│     [Status]     Up About an hour
│     [Size]       0B (virtual 232MB)
│     [Names]      prometheus
│     [Networks]   deployments_default
└─────────────────
```
