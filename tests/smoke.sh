#!/bin/sh
# The smoke checks of the spec (AC-01.1 to AC-01.5, RN-GW-02 to RN-GW-05), plus `nginx -t`.
# It builds the image, starts the gateway on a private network and checks it through HTTP. Docker is
# the only requirement; the CI and a developer run this same file. It touches nothing else and
# writes no secret: the only variable is the origin of the container, and it is a placeholder.
set -u
cd "$(dirname "$0")/.." || exit 1

# Git Bash on Windows rewrites container paths; no effect elsewhere
export MSYS_NO_PATHCONV=1

RUN_ID="gateway-smoke-$$"
ORIGIN="http://localhost:4200"
UNKNOWN_ORIGIN="http://evil.example"
TMP=$(mktemp -d) || exit 1
fail=0

cleanup() {
  docker rm -f "$RUN_ID" >/dev/null 2>&1 || true
  docker network rm "$RUN_ID" >/dev/null 2>&1 || true
  docker rmi "$RUN_ID" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 1' INT TERM

pass() { echo "PASS  $1"; }
miss() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=1; }

# status NAME WANT CURL-ARGS...
status() {
  name=$1; want=$2; shift 2
  got=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$got" = "$want" ]; then pass "$name"; else miss "$name" "want $want, got $got"; fi
}

# has NAME PATTERN CURL-ARGS...: the headers and body must contain the pattern
has() {
  name=$1; want=$2; shift 2
  if curl -s -i "$@" | grep -qi -- "$want"; then pass "$name"; else miss "$name" "missing: $want"; fi
}

# lacks NAME PATTERN CURL-ARGS...
lacks() {
  name=$1; bad=$2; shift 2
  if curl -s -i "$@" | grep -qi -- "$bad"; then miss "$name" "found: $bad"; else pass "$name"; fi
}

# ---- build, then validate the configuration the way the image runs it
if ! docker build -q -f deploy/Dockerfile -t "$RUN_ID" . >/dev/null 2>"$TMP/build.log"; then
  echo "FAIL  the gateway image did not build"
  tail -n 5 "$TMP/build.log" | sed 's/^/        /'
  exit 1
fi
if docker run --rm -e ALLOWED_ORIGIN="$ORIGIN" "$RUN_ID" nginx -t >"$TMP/nginx-t.log" 2>&1; then
  pass "nginx -t"
else
  miss "nginx -t" "$(tail -n 3 "$TMP/nginx-t.log")"
fi

docker network create "$RUN_ID" >/dev/null || exit 1
docker run -d --name "$RUN_ID" --network "$RUN_ID" -e ALLOWED_ORIGIN="$ORIGIN" -p 127.0.0.1::8080 "$RUN_ID" >/dev/null || exit 1
PORT=$(docker port "$RUN_ID" 8080/tcp | head -n 1 | sed 's/.*://')
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 30); do
  curl -s -o /dev/null "$BASE/health" && break
  sleep 1
done

# ---- the checks
status "smoke·health_is_200" 200 "$BASE/health"
status "smoke·unknown_route_is_404" 404 "$BASE/nope"
has    "smoke·unknown_route_uses_the_envelope" '"error":"NOT_FOUND"' "$BASE/nope"
has    "smoke·correlation_is_created" 'X-Correlation-Id: [A-Za-z0-9]' "$BASE/health"
has    "smoke·correlation_is_kept" 'X-Correlation-Id: smoke-1' -H 'X-Correlation-Id: smoke-1' "$BASE/health"
lacks  "smoke·unsafe_correlation_is_replaced" 'X-Correlation-Id: not safe' -H 'X-Correlation-Id: not safe' "$BASE/health"
status "smoke·preflight_is_204" 204 -X OPTIONS -H "Origin: $ORIGIN" "$BASE/api/v1/anything"
has    "smoke·preflight_allows_the_headers" 'Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key, X-Correlation-Id' -X OPTIONS -H "Origin: $ORIGIN" "$BASE/api/v1/anything"
has    "smoke·cors_exposes_correlation_and_location" 'Access-Control-Expose-Headers: X-Correlation-Id, Location' -H "Origin: $ORIGIN" "$BASE/health"
lacks  "smoke·unknown_origin_gets_no_cors" 'Access-Control-Allow-Origin' -H "Origin: $UNKNOWN_ORIGIN" "$BASE/health"
status "smoke·internal_is_404" 404 "$BASE/api/v1/security/internal/anything" -H 'Authorization: Bearer x'
has    "smoke·every_response_carries_the_security_headers" 'X-Content-Type-Options: nosniff' "$BASE/health"
has    "smoke·every_response_is_not_cached" 'Cache-Control: no-store' "$BASE/health"
head -c 1500000 /dev/zero > "$TMP/large.bin"
status "smoke·body_over_limit_is_413" 413 -X POST --data-binary "@$TMP/large.bin" "$BASE/nope"
has    "smoke·body_over_limit_uses_the_envelope" '"error":"PAYLOAD_TOO_LARGE"' -X POST --data-binary "@$TMP/large.bin" "$BASE/nope"

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
