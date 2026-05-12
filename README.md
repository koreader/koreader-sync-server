[![AGPL Licence][licence-badge]](COPYING)

# KOReader Sync Server

A self-hosted reading progress sync server for [KOReader](https://koreader.rocks/)
devices. Built on [OpenResty](https://openresty.org/) (nginx + Lua) with Redis
for storage.

Register your KOReader devices and keep reading progress synchronised across
all of them — Kindle, Kobo, PocketBook, Android, desktop, whatever runs
KOReader.

## Features

- **Reading progress sync** — tracks percentage, position, device, and
  timestamp per document per user
- **Admin dashboard** — web UI at `/admin` showing all users, documents,
  progress bars, and last-sync times
- **Logs viewer** — live access and application logs with color-coded status,
  auto-refresh toggle
- **User management** — delete users or reset passwords from the dashboard
- **Security hardened** — SHA-1 hashed passwords, TLS 1.2/1.3 only, rate
  limiting, security headers, HttpOnly admin cookie
- **Docker-ready** — single container with Redis, nginx, and the app; data
  persisted via volumes

## Quick Start

### Docker run

```bash
mkdir -p ./logs/{redis,app} ./data/redis

docker build --tag=koreader/kosync .

docker run -d -p 7200:7200 \
    -e ADMIN_PASSWORD=your-secret \
    -v $(pwd)/logs/app:/app/koreader-sync-server/logs \
    -v $(pwd)/logs/redis:/var/log/redis \
    -v $(pwd)/data/redis:/var/lib/redis \
    --name=kosync koreader/kosync
```

### Docker Compose

```bash
docker compose up -d --build
```

See `docker-compose.yml` — edit the `ADMIN_PASSWORD` environment variable
before starting.

### Verify it works

```bash
curl -k https://localhost:7200/healthcheck
# {"state":"OK"}
```

The healthcheck now verifies Redis connectivity — if Redis is down it
returns `503 {"state":"FAIL"}`.

## Configuration

| Environment Variable | Default | Description |
|---|---|---|
| `ENABLE_USER_REGISTRATION` | `true` | Initial default for new sign-ups. Can be toggled at runtime via the admin Settings tab |
| `ADMIN_PASSWORD` | *(unset)* | Password for the admin dashboard. **Required** — the dashboard is disabled until this is set |

## Admin Dashboard

Access the dashboard at `https://your-server:7200/admin`.

- **Dashboard tab** — lists all registered users with their synced documents,
  reading progress bars, device names, and last-sync timestamps. Includes
  search/filter and user management (delete user, reset password).
- **Logs tab** — shows the last 200 lines of the nginx access log and
  application log. Lines are color-coded by HTTP status (2xx/3xx/4xx/5xx) and
  severity (info/warn/error). Supports auto-refresh (3–60 second interval).

## KOReader Client Setup

On your KOReader device:

1. Go to **Tools → Cloud storage & sync → Progress sync**
2. Set the server to `https://your-server:7200`
3. Register a new account or log in with existing credentials
4. Enable "auto sync" to sync on every page turn

All devices using the same account will share reading positions.

## Running Behind a Reverse Proxy

The server listens on two ports inside the container:

| Port | Protocol |
|---|---|
| `7200` | HTTPS (self-signed cert) |
| `17200` | HTTP (plain, for reverse proxy termination) |

If your reverse proxy handles TLS, point it at port `17200`:

```yaml
# Traefik v3 example
services:
  kosync:
    # ...
    labels:
      - traefik.enable=true
      - 'traefik.http.routers.kosync.rule=Host(`sync.example.com`)'
      - 'traefik.http.services.kosync.loadbalancer.server.port=17200'
```

## API Endpoints

All endpoints are versioned under `/1/` and expect the header
`Accept: application/vnd.koreader.v1+json`.

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/1/users/create` | — | Register `{username, password}` |
| `GET` | `/1/users/auth` | `x-auth-user` + `x-auth-key` | Verify credentials |
| `PUT` | `/1/syncs/progress` | `x-auth-user` + `x-auth-key` | Update reading position |
| `GET` | `/1/syncs/progress/:document` | `x-auth-user` + `x-auth-key` | Get reading position |
| `GET` | `/healthcheck` | — | Server + Redis health |

## Privacy & Security

- **No filenames stored** — documents are identified by a 32-character MD5 hash
  generated client-side by KOReader. The server never sees the actual filename.
- **Passwords hashed** — stored as salted SHA-1 hashes in Redis. Existing
  plaintext passwords from older versions are transparently upgraded to hashed
  on next login.
- **TLS enforced** — the server uses a self-signed certificate by default.
  Deploy behind a reverse proxy with a real certificate for production use.
- **Rate limited** — 10 requests/second per IP with burst allowance of 20.
- **Security headers** — `X-Frame-Options: DENY`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy`.
- **Admin access** — protected by a separate password with HttpOnly,
  SameSite=Strict cookies.

## Docker Logging

Nginx access and application logs stream to the container's stdout/stderr, so
`docker logs -f kosync` shows live traffic. Logs are also written to files in
the mounted `./logs/app` volume.

## Upgrading from the Original Version

This fork is a drop-in replacement for the upstream
[koreader/koreader-sync-server](https://github.com/koreader/koreader-sync-server).

**Data is fully compatible** — the Redis schema (key patterns, hash fields) is
unchanged. Your existing users, documents, and reading positions carry over
without any migration.

**KOReader devices won't notice** — the sync API is identical. No client-side
changes needed.

### What to know

- **Passwords are now hashed.** The original stored passwords as plaintext in
  Redis. This version stores salted SHA-1 hashes. Existing plaintext passwords
  are **automatically upgraded** to hashed on the user's next login — no manual
  action required.
- **Downgrading after upgrade** will lock out any user whose password was
  already migrated to a hash, since the old code expects plaintext.
- **`ADMIN_PASSWORD` is required** for the admin dashboard. Set it in your
  environment or `docker-compose.yml`. The dashboard is disabled without it.
- **New log volume.** Mount `./logs/app:/app/koreader-sync-server/logs` to
  persist nginx access and application logs. Optional — logs stay inside the
  container if not mounted.

### Upgrade steps

```bash
# Stop the old container
docker stop kosync && docker rm kosync

# Pull/build the new image
docker build --tag=koreader/kosync .

# Start with the same Redis data volume and add new config
docker run -d -p 7200:7200 \
    -e ADMIN_PASSWORD=your-secret \
    -v /path/to/existing/redis:/var/lib/redis \
    -v $(pwd)/logs/app:/app/koreader-sync-server/logs \
    -v $(pwd)/logs/redis:/var/log/redis \
    --name=kosync koreader/kosync
```

Or with Docker Compose, update your `docker-compose.yml` to add the
`ADMIN_PASSWORD` environment variable and the logs volume, then:

```bash
docker compose up -d --build
```

## Development

Run the test suite inside the container:

```bash
docker exec kosync bash -c "cd /app/koreader-sync-server && make test"
```

Or build and run tests from scratch:

```bash
docker build --tag=koreader/kosync .
docker run --rm koreader/kosync bash -c \
    "cd /app/koreader-sync-server && scripts/run_tests.sh"
```

## License

AGPL v3 — see [COPYING](COPYING).

[licence-badge]: http://img.shields.io/badge/licence-AGPL-brightgreen.svg
