# multi-tour-api-gateway

> Single entry point: authentication, routing and rate limiting

Part of the **LMS Library** distributed system — team `lms-library`, Grupo 2.
Governance and documentation live in [`library-docs`](https://github.com/code-corhuila/library-docs).

## What it is

The only entry point of the platform and the only service that publishes a port besides Grafana (norm §5.6.1). It is NGINX configuration, not code: no business logic, no database, no migrations. It routes `/api/v1/<domain>/...` to its service, filters that a protected route carries a credential, answers its own errors with the common envelope, and passes `X-Correlation-Id`. It never validates a token: every service does.

## How to start it

To be written with the routes and the compose file (tasks T-04 and T-05).

## Where the data is

It keeps none. Its configuration is in `nginx/`; the only variable is `ALLOWED_ORIGIN` (`.env.example`).

## How to test it

`sh tests/smoke.sh` builds the image, runs `nginx -t` and checks the gateway over HTTP; it needs Docker. The CI runs the same file on every pull request to `develop` and `qa`.

## What is missing

The routes of each domain and the sagas, the compose file and the rest of the checks: see `07-api/specs/transversal/multi-tour-api-gateway/` in `multi-tour-docs`.

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

Full policy: `00-governance/branching-policy.md` in `library-docs`.
