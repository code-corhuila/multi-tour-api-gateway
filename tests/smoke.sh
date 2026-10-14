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
  docker rm -f "$RUN_ID" "$RUN_ID-stub" "$RUN_ID-front" >/dev/null 2>&1 || true
  docker network rm "$RUN_ID" >/dev/null 2>&1 || true
  docker rmi "$RUN_ID" "$RUN_ID-stub" >/dev/null 2>&1 || true
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

# lacks NAME PATTERN CURL-ARGS...: the gateway must answer, and the answer must not contain the pattern
lacks() {
  name=$1; bad=$2; shift 2
  answer=$(curl -s -i "$@")
  case $answer in HTTP/*) ;; *) miss "$name" "the gateway did not answer"; return ;; esac
  if printf '%s\n' "$answer" | grep -qi -- "$bad"; then miss "$name" "found: $bad"; else pass "$name"; fi
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
# The stub answers as four domains, on their ports, and says which port was reached. identity-audit and
# the sagas are stopped: a stopped service must answer 503 while the others keep working (norm §5.6.3).
docker build -q -t "$RUN_ID-stub" tests/stub >/dev/null || { echo "the stub service did not build"; exit 1; }
docker run -d --name "$RUN_ID-stub" --network "$RUN_ID" \
  --network-alias multi-tour-security \
  --network-alias multi-tour-commercial-reservation-api \
  --network-alias multi-tour-operations-cost-api \
  --network-alias multi-tour-cash-reporting-api \
  "$RUN_ID-stub" >/dev/null || exit 1
docker run -d --name "$RUN_ID" --network "$RUN_ID" -e ALLOWED_ORIGIN="$ORIGIN" -p 127.0.0.1::8080 "$RUN_ID" >/dev/null || exit 1
PORT=$(docker port "$RUN_ID" 8080/tcp | head -n 1 | sed 's/.*://')
BASE="http://127.0.0.1:$PORT"
for _ in $(seq 1 30); do
  curl -s -o /dev/null "$BASE/health" && break
  sleep 1
done

# ---- the checks
status "smoke·health_is_200" 200 "$BASE/health"
status "smoke·unknown_route_is_404" 404 "$BASE/api/v1/nope"
has    "smoke·unknown_route_uses_the_envelope" '"error":"NOT_FOUND"' "$BASE/api/v1/nope"
has    "smoke·correlation_is_created" 'X-Correlation-Id: [A-Za-z0-9]' "$BASE/health"
has    "smoke·correlation_is_kept" 'X-Correlation-Id: smoke-1' -H 'X-Correlation-Id: smoke-1' "$BASE/health"
lacks  "smoke·unsafe_correlation_is_replaced" 'X-Correlation-Id: not safe' -H 'X-Correlation-Id: not safe' "$BASE/health"
LONG=$(head -c 140 /dev/zero | tr '\000' a)
lacks  "smoke·long_correlation_is_replaced" "$LONG" -H "X-Correlation-Id: $LONG" "$BASE/health"
status "smoke·preflight_is_204" 204 -X OPTIONS -H "Origin: $ORIGIN" "$BASE/api/v1/anything"
has    "smoke·preflight_allows_the_headers" 'Access-Control-Allow-Headers: Authorization, Content-Type, Idempotency-Key, X-Correlation-Id' -X OPTIONS -H "Origin: $ORIGIN" "$BASE/api/v1/anything"
has    "smoke·allowed_origin_gets_the_grant" "Access-Control-Allow-Origin: $ORIGIN" -H "Origin: $ORIGIN" "$BASE/health"
has    "smoke·preflight_of_the_allowed_origin_gets_the_grant" "Access-Control-Allow-Origin: $ORIGIN" -X OPTIONS -H "Origin: $ORIGIN" "$BASE/api/v1/anything"
lacks  "smoke·preflight_of_an_unknown_origin_gets_no_grant" 'Access-Control-Allow-Origin' -X OPTIONS -H "Origin: $UNKNOWN_ORIGIN" "$BASE/api/v1/anything"
has    "smoke·cors_varies_by_origin" 'Vary: Origin' "$BASE/health"
has    "smoke·cors_exposes_correlation_and_location" 'Access-Control-Expose-Headers: X-Correlation-Id, Location' -H "Origin: $ORIGIN" "$BASE/health"
lacks  "smoke·unknown_origin_gets_no_cors" 'Access-Control-Allow-Origin' -H "Origin: $UNKNOWN_ORIGIN" "$BASE/health"
has    "smoke·every_response_carries_the_security_headers" 'X-Content-Type-Options: nosniff' "$BASE/health"
has    "smoke·every_response_is_not_cached" 'Cache-Control: no-store' "$BASE/health"
has    "smoke·the_404_carries_the_headers" 'X-Content-Type-Options: nosniff' "$BASE/api/v1/nope"
head -c 1500000 /dev/zero > "$TMP/large.bin"
# the native curl of Windows needs a Windows path for the file; elsewhere cygpath does not exist
LARGE="$TMP/large.bin"
command -v cygpath >/dev/null 2>&1 && LARGE=$(cygpath -m "$LARGE")
status "smoke·body_over_limit_is_413" 413 -X POST --data-binary "@$LARGE" "$BASE/api/v1/nope"
has    "smoke·the_413_carries_the_headers" 'Cache-Control: no-store' -X POST --data-binary "@$LARGE" "$BASE/api/v1/nope"
has    "smoke·body_over_limit_uses_the_envelope" '"error":"PAYLOAD_TOO_LARGE"' -X POST --data-binary "@$LARGE" "$BASE/api/v1/nope"

# ---- the routes (T-04)
AUTH='Authorization: Bearer smoke'
UP="$BASE/api/v1/security/accounts"
DOWN="$BASE/api/v1/identity-audit/tenants"
status "smoke·protected_route_without_token_is_401" 401 "$DOWN"
has    "smoke·the_401_uses_the_envelope" '"error":"UNAUTHORIZED"' "$DOWN"
has    "smoke·the_401_carries_the_headers" 'Cache-Control: no-store' "$DOWN"
has    "smoke·security_is_reached_on_8086" '"port":"8086"' -H "$AUTH" "$UP"
status "smoke·public_route_passes_without_token" 200 "$BASE/api/v1/security/public/tenants/acme/sign-in"
status "smoke·stopped_service_is_503" 503 -H "$AUTH" "$DOWN"
has    "smoke·the_503_uses_the_envelope" '"error":"SERVICE_UNAVAILABLE"' -H "$AUTH" "$DOWN"
status "smoke·the_others_keep_working_while_one_is_stopped" 200 -H "$AUTH" "$UP"
for entry in commercial-reservation:8083 operations-cost:8084 cash-reporting:8085; do
  domain=${entry%%:*}; port=${entry##*:}
  has "smoke·${domain}_is_reached_on_$port" "\"port\":\"$port\"" -H "$AUTH" "$BASE/api/v1/$domain/anything"
done
# each saga must point at its own workflow: a crossed host would still answer 503, so the file is read
for saga in onboard-tenant register-payment execute-refund cancel-departure change-departure-vehicles; do
  target=$(awk -v s="$saga" 'index($0, "sagas/" s) && /location/ {f=1} f && /set .target/ {print; exit}' nginx/routes/sagas.conf)
  case $target in *"http://multi-tour-workflow-$saga:8090;"*) pass "smoke·saga_${saga}_points_at_its_workflow" ;; *) miss "smoke·saga_${saga}_points_at_its_workflow" "found: $target" ;; esac
done
status "smoke·a_saga_prefix_is_not_a_saga" 404 -X POST -H "$AUTH" "$BASE/api/v1/sagas/onboard-tenantX"
for saga in onboard-tenant register-payment execute-refund cancel-departure change-departure-vehicles; do
  status "smoke·saga_${saga}_needs_a_credential" 401 -X POST "$BASE/api/v1/sagas/$saga"
  status "smoke·saga_${saga}_is_routed" 503 -X POST -H "$AUTH" "$BASE/api/v1/sagas/$saga"
done
status "smoke·internal_is_404" 404 -H "$AUTH" "$BASE/api/v1/security/internal/anything"
status "smoke·internal_with_a_path_parameter_is_404" 404 -H "$AUTH" "$BASE/api/v1/security/internal;x=1/anything"
status "smoke·internal_in_capitals_is_404" 404 -H "$AUTH" "$BASE/api/v1/security/INTERNAL/anything"
status "smoke·internal_after_a_line_break_is_404" 404 -H "$AUTH" "$BASE/api/v1/security/a%0a/internal/anything"
status "smoke·body_over_limit_on_a_route_is_413" 413 -X POST -H "$AUTH" --data-binary "@$LARGE" "$UP"
has    "smoke·the_credential_route_keeps_its_413_envelope" '"error":"PAYLOAD_TOO_LARGE"' -X POST --data-binary "@$LARGE" "$BASE/api/v1/security/public/tenants/acme/sign-in"
has    "smoke·correlation_reaches_the_service" '"correlation":"smoke-2"' -H "$AUTH" -H 'X-Correlation-Id: smoke-2' "$UP"
lacks  "smoke·a_forged_forwarded_for_is_not_passed_on" '6.6.6.6' -H "$AUTH" -H 'X-Forwarded-For: 6.6.6.6' "$UP"
lacks  "smoke·the_correlation_header_of_the_service_is_hidden" 'from-the-service' -H "$AUTH" "$UP"
lacks  "smoke·the_cache_header_of_the_service_is_hidden" 'Cache-Control: public' -H "$AUTH" "$UP"
# ---- the front on the same origin (the browser reaches the shell and the API through one address)
# The front is not started yet: the root answers the 503 envelope, with no credential asked.
status "smoke·root_without_the_front_is_503" 503 "$BASE/"
has    "smoke·the_root_503_uses_the_envelope" '"error":"SERVICE_UNAVAILABLE"' "$BASE/portals/identity-audit/remoteEntry.json"
# A portal that is not running answers the 503 envelope on its own module, with no credential asked, and
# the other routes keep answering (the area of that portal is the only one that goes down).
for p in identity-audit operations-cost commercial-reservation; do
  status "smoke·portal_${p}_module_down_is_503" 503 "$BASE/portals/${p}-portal.js"
  has    "smoke·portal_${p}_503_uses_the_envelope" '"error":"SERVICE_UNAVAILABLE"' "$BASE/portals/${p}-portal.css"
done
status "smoke·unknown_api_path_is_404_not_the_front" 404 -H "$AUTH" "$BASE/api/nope"
status "smoke·api_without_token_is_still_401" 401 "$DOWN"
# a saga may outlast the 70 s bound of the workflow, so its read timeout is 90 s
for saga in onboard-tenant register-payment execute-refund cancel-departure change-departure-vehicles; do
  t=$(awk -v s="$saga" 'index($0, "sagas/" s) && /location/ {f=1} f && /proxy_read_timeout/ {print $2; exit}' nginx/routes/sagas.conf)
  if [ "$t" = "90s;" ]; then pass "smoke·saga_${saga}_waits_90s"; else miss "smoke·saga_${saga}_waits_90s" "found: $t"; fi
done
docker run -d --name "$RUN_ID-front" --network "$RUN_ID" --network-alias multi-tour-front "$RUN_ID-stub" >/dev/null || exit 1
# above the 10 s the resolver keeps the failed lookup of the front (valid=10s)
sleep 13
status "smoke·root_reaches_the_front_without_token" 200 "$BASE/"
has    "smoke·root_is_served_by_the_front_on_8080" '"port":"8080"' "$BASE/index.html"
has    "smoke·the_manifest_keeps_the_cache_header_of_the_front" 'Cache-Control: no-cache' "$BASE/federation.manifest.json"
lacks  "smoke·the_manifest_is_not_forced_to_no_store" 'Cache-Control: no-store' "$BASE/federation.manifest.json"
has    "smoke·portals_keep_the_cache_header_of_the_front" 'Cache-Control: no-cache' "$BASE/portals/identity-audit/remoteEntry.json"
has    "smoke·the_front_response_carries_one_correlation_id" 'X-Correlation-Id: [A-Za-z0-9]' "$BASE/"
lacks  "smoke·the_cors_headers_of_the_front_are_hidden" 'Access-Control-Allow-Origin' "$BASE/portals/identity-audit/remoteEntry.json"
lacks  "smoke·the_front_correlation_header_is_hidden" 'from-the-service' "$BASE/"

# the credential routes take the stricter zone: 60 per minute, burst 20, so the 40th request in a row is limited
SIGN_IN="$BASE/api/v1/security/public/tenants/acme/sign-in"
limited=0; first=0; last=''
for n in $(seq 1 40); do
  out=$(curl -s -i "$SIGN_IN")
  case $(printf '%s' "$out" | head -n 1) in
    *" 429"*) limited=$((limited + 1)); last=$out; [ "$first" = 0 ] && first=$n ;;
  esac
done
if [ "$limited" -ge 1 ]; then pass "smoke·rate_limit_is_429"; else miss "smoke·rate_limit_is_429" "40 requests in a row were never limited"; fi
if [ "$first" -ge 21 ]; then pass "smoke·the_burst_of_20_is_honored"; else miss "smoke·the_burst_of_20_is_honored" "the first 429 came at request $first"; fi
# the answers are read from a 429 the loop already got, not from a new request that might find a free slot
if printf '%s\n' "$last" | grep -qi 'Retry-After: 60'; then pass "smoke·the_429_has_retry_after"; else miss "smoke·the_429_has_retry_after" "missing: Retry-After: 60"; fi
if printf '%s\n' "$last" | grep -qi '"error":"TOO_MANY_REQUESTS"'; then pass "smoke·the_429_uses_the_envelope"; else miss "smoke·the_429_uses_the_envelope" "missing the envelope"; fi

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
