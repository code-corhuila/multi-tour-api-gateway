# multi-tour-api-gateway

> Single entry point of the platform: routing, credential filter and rate limiting (NGINX configuration)

Part of the **Multi Tour** distributed system — team `multi-tour`, Grupo 2.
Governance and documentation live in [`multi-tour-docs`](https://github.com/code-corhuila/multi-tour-docs).

## What it is

The only entry point of the platform and the only service that publishes a port besides Grafana (norm §5.6.1). It is NGINX configuration, not code: no business logic, no database, no migrations. It routes `/api/v1/<domain>/...` to its service, filters that a protected route carries a credential, answers its own errors with the common envelope, and passes `X-Correlation-Id`. It never validates a token: every service does.

## How to start it

Needs Docker. Copy `.env.example` to `.env` (never versioned) and set `ALLOWED_ORIGIN` to the origin of `multi-tour-front`; the compose file refuses to start without it. It publishes port `8080`, the only one of the platform besides Grafana, on the network `platform`, which `multi-tour-infra-postgres/scripts/up.sh` creates. The root composition of that repository includes `deploy/compose.yml`; alone, from this folder: `docker compose --env-file .env -f deploy/compose.yml up -d --build`.

| Route | Goes to | Rule |
|---|---|---|
| `/health` | the gateway itself | no credential |
| `/api/v1/<domain>/public/…` | the service of the domain | no credential |
| `/api/v1/<domain>/…` | `multi-tour-security:8086`, `multi-tour-identity-audit-api:8082`, `…-commercial-reservation-api:8083`, `…-operations-cost-api:8084`, `…-cash-reporting-api:8085` | `Authorization` header required, else `401` |
| `/api/v1/sagas/<saga>…` | `multi-tour-workflow-<saga>:8090` | `Authorization` header required |
| `/api/v1/<domain>/internal/…` | nowhere | always `404` (ADR-004 D5) |
| `/api/…` with no route | nowhere | `404` envelope |
| everything else (`/`, `/portals/…`, `federation.manifest.json`) | `multi-tour-front:8080` | no credential; the front sets the cache headers; `503` envelope if it is down |

The browser reaches the page and the API through this one origin. A service that is down answers `503` and the rest keep working. Limits: 1 MB body, 50 requests per second per client and 60 per minute on the credential routes of `security/public`.

## Where the data is

It keeps none. Its configuration is in `nginx/`; the only variable is `ALLOWED_ORIGIN` (`.env.example`).

## How to test it

`sh tests/smoke.sh` builds the image, runs `nginx -t` and checks the gateway over HTTP; it needs Docker. The CI runs the same file on every pull request to `develop` and `qa`.

## What is missing

The 6 MB limit of the proof-upload route, because no contract defines its path yet (it is added with the story that does), and HSTS, which belongs to the environments with TLS (ADR-004 D2). The spec and the plan are in `07-api/specs/transversal/multi-tour-api-gateway/` of `multi-tour-docs`.

## Branching

Three permanent branches. **None of them accepts a direct commit** — you enter through a child
branch and leave through a Pull Request.

```
develop  <--PR--  feat/... fix/... chore/...
qa       <--PR--  qa/...
main     <--PR--  release/...  hotfix/...
```

Promotion happens **by re-application** (`git cherry-pick -x`), never by merging one permanent
branch into another: `merge develop -> qa` and `merge qa -> main` do not exist in this model.

`main` requires **1 approval from `ariel5253`**. On `develop` and `qa` the team sets its own review
rule.

Full policy: `00-governance/branching-policy.md` in `multi-tour-docs`.
