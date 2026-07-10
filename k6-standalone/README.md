# QuickPizza k6 — Standalone Package

Self-contained layout for running and extending the QuickPizza k6 test suite **without** building the Go app or frontend from source.

k6 scripts are **clients**; they need a running QuickPizza instance (Docker image or hosted demo).

## Folder layout

Use this repo as-is from the monorepo, or copy `k6-standalone/` plus `k6/` into a new repository:

```
my-k6-quickpizza/
├── k6/                          # copy from quickpizza/k6/
│   ├── foundations/
│   ├── browser/
│   ├── internal/
│   ├── extensions/
│   ├── jslibs/
│   └── run-tests.sh
├── proto/                       # only for gRPC tier (copy proto/quickpizza.proto)
├── docker-compose.yml           # QuickPizza target (HTTP :3333)
├── docker-compose.postgres.yml  # optional: PostgreSQL extension tier
├── .env.example
├── run-tier.sh                  # Linux / macOS / Git Bash
├── run-tier.ps1                 # Windows PowerShell
├── tiers/                       # which scripts belong to each tier
└── README.md
```

From the QuickPizza monorepo, `K6_ROOT` defaults to `../k6` so you can run tiers without copying files.

## Prerequisites

| Tier | k6 | Extra |
|------|-----|-------|
| `basic` | k6 v1.0+ | — |
| `auth` | k6 v1.0+ | QuickPizza with user APIs |
| `websockets` | k6 v1.0+ | WebSocket service on target |
| `browser` | k6 with browser module | Chrome / Chromium |
| `grpc` | k6 v1.0+ | gRPC on port 3334 + `proto/quickpizza.proto` |
| `extensions` | varies | xk6 custom binary and/or Postgres and/or Prometheus |

Install k6: https://grafana.com/docs/k6/latest/set-up/install-k6/

## Quick start

### 1. Start the target app

```bash
docker compose up -d
```

Or use the hosted demo (no local Docker):

```bash
export BASE_URL=https://quickpizza.grafana.com   # Linux/macOS
$env:BASE_URL = "https://quickpizza.grafana.com" # PowerShell
```

### 2. Run a tier

```bash
# Git Bash / Linux / macOS
./run-tier.sh basic

# Windows PowerShell
.\run-tier.ps1 -Tier basic
```

### 3. Run everything that CI runs (no optional tiers)

```bash
./run-tier.sh ci
# or
.\run-tier.ps1 -Tier ci
```

## Test tiers

### `basic` — core HTTP load tests

Standard k6 only. Hits `GET /` and `POST /api/pizza`.

Includes: `foundations/01`–`12`, `14`, `15` (tracing/profiling are client-side instrumentation).

Does **not** need gRPC, WebSockets, login flows, browser, or custom extensions.

### `auth` — authentication & ratings API

- `foundations/17.login-action.js`
- `internal/01.quickpizza.js`

Requires QuickPizza user/CSRF endpoints. Uses seeded user `synthetics_multihttp_example` in the default in-memory DB.

### `websockets` — real-time messaging

- `foundations/13.basic.websockets.js`

Requires `ws://<host>/ws` on the target (enabled in default monolith / Docker image).

### `browser` — UI & hybrid tests

All scripts in `k6/browser/`. Requires k6 browser module and a headless browser.

```bash
export K6_BROWSER_HEADLESS=true
./run-tier.sh browser
```

On Linux CI, set `K6_BROWSER_EXECUTABLE_PATH=/usr/bin/google-chrome-stable` if bundled Chromium fails.

### `grpc` — gRPC pizza rating

- `foundations/16.grpc.js`

Requires:

- QuickPizza gRPC listener on **3334** (set `QUICKPIZZA_ENABLE_GRPC_SERVICE=true` if disabled)
- `proto/quickpizza.proto` at repo root (or set `BASE_GRPC_URL`)

```bash
export BASE_GRPC_URL=localhost:3334
k6 run k6/foundations/16.grpc.js
```

### `extensions` — xk6 & external systems

| Script | Target | Build |
|--------|--------|-------|
| `01.quickpizzaext.js` | QuickPizza HTTP | Custom k6 via xk6 (see below) |
| `02.prometheus-client.js` | Prometheus remote write | xk6 + remotewrite |
| `03.postgresql.js` | PostgreSQL directly | Standard k6 (xk6-sql auto-resolves) |

**Build quickpizzaext binary (from monorepo root):**

```bash
go install go.k6.io/xk6/cmd/xk6@latest
xk6 build \
  --output k6/extensions/k6 \
  --with github.com/grafana/quickpizza/extensions/quickpizzaext=./k6/extensions/quickpizzaext \
  --replace github.com/grafana/quickpizza=.
./k6/extensions/k6 run k6/extensions/01.quickpizzaext.js
```

When extracting to a separate repo, either keep a `replace` to a vendored `pkg/model` copy or inline the pizza restriction logic in the extension (see `k6/extensions/quickpizzaext/main.go`).

**PostgreSQL tier:**

```bash
docker compose -f docker-compose.yml -f docker-compose.postgres.yml up -d
k6 run k6/extensions/03.postgresql.js
```

**Prometheus tier:**

```bash
xk6 build --output k6/extensions/k6-prom \
  --with github.com/grafana/xk6-client-prometheus-remote@latest
./k6/extensions/k6-prom run k6/extensions/02.prometheus-client.js \
  -e RW_URL=http://localhost:9090/api/v1/write
```

### `ci` — matches QuickPizza CI

Runs: `basic` + `auth` + `browser` + `01.quickpizzaext.js` (after building xk6 binary).

Does **not** run: `grpc`, `02.prometheus-client.js`, `03.postgresql.js`.

## Environment variables

| Variable | Default | Used by |
|----------|---------|---------|
| `BASE_URL` | `http://localhost:3333` | Most HTTP / browser tests |
| `BASE_GRPC_URL` | `localhost:3334` | `16.grpc.js` |
| `RW_URL` | `http://localhost:9090/api/v1/write` | `02.prometheus-client.js` |
| `K6_ROOT` | `../k6` (monorepo) or `./k6` (extracted) | Tier runners |
| `K6_PATH` | `k6` | Tier runners |
| `K6_BROWSER_HEADLESS` | `true` | Browser tier |

Copy `.env.example` to `.env` and adjust as needed.

## What you do **not** need

For k6-only work, you can ignore:

- `pkg/web/`, `pkg/http/`, and most Go backend source (use the Docker image instead)
- `compose.grafana-*.yaml`, `deployments/`, Terraform
- Observability stacks (unless you are demoing tracing/metrics correlation)

## Extracting to a new repository

```bash
# From quickpizza repo root
mkdir ../my-k6-quickpizza
cp -r k6 ../my-k6-quickpizza/
cp -r k6-standalone/* ../my-k6-quickpizza/
cp proto/quickpizza.proto ../my-k6-quickpizza/proto/
cd ../my-k6-quickpizza
# Set K6_ROOT=./k6 in .env or export it
```

Then enhance scripts under `k6/` independently; point `BASE_URL` at any QuickPizza deployment.

## Enhancement ideas

- Add new scenarios under `k6/foundations/` using shared helpers in `k6/foundations/lib/`
- Extend page objects in `k6/browser/pages/` for new UI flows
- Add custom xk6 extensions under `k6/extensions/<name>/`
- Register new tiers in `tiers/*.txt` and `run-tier.sh`
