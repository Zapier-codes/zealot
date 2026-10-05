#!/usr/bin/env bash
# Task 40n-h: runs add-r2-adapter-vars.sh and enable-pipeline.sh against the stub in mock_render.py and checks that
# neither calls a variable change "done" until a NEW deploy is live. Needs bash, python3, curl, jq. No network, no secrets.
#   bash docs/ci/test/test-render-deploy.sh
set -u
T="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; CI="$(dirname "$T")"
PID=""; W=$(mktemp -d); trap 'kill $PID 2>/dev/null; rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/home"
# a fake gh so the storage-repo gates of enable-pipeline.sh can pass without GitHub
cat > "$W/bin/gh" <<'GH'
#!/usr/bin/env bash
case "$1 $2" in
  "variable get") case "$3" in ZEALOT_URL) echo https://zealot.example;; R2_STAGING_ENDPOINT) echo https://r2.example;;
                  R2_STAGING_BUCKET) echo zealot-staging;; RELEASE_CERT_SHA256) printf 'a%.0s' $(seq 64);; esac ;;
  "secret list") for s in RELEASE_KEYSTORE_BASE64 RELEASE_KEYSTORE_PASSWORD RELEASE_KEY_ALIAS CI_COMPILE_CALLBACK_TOKEN \
                          R2_STAGING_CI_ACCESS_KEY_ID R2_STAGING_CI_SECRET_ACCESS_KEY; do echo "$s  now"; done ;;
  "api repos"*) git hash-object "$GH_STUB_FILE" ;;
esac
GH
chmod +x "$W/bin/gh"
export PATH="$W/bin:$PATH" HOME="$W/home" RENDER_API_KEY=rnd_test RENDER_SERVICE_ID=srv-test \
  GH_STUB_FILE="$CI/read-upload.yml" DEPLOY_GRACE=2 DEPLOY_POLL=1 DEPLOY_SETTLE=1 DEPLOY_MAX=25
PORT=$((20000 + RANDOM % 20000)); pass=0; failn=0
start() { : > "$W/log"; kill $PID 2>/dev/null; python3 "$T/mock_render.py" "$PORT" "$1" "$W/log" & PID=$!
  export RENDER_API_URL="http://127.0.0.1:$PORT/v1"; for _ in $(seq 30); do curl -s "$RENDER_API_URL/services/srv-test/deploys" >/dev/null && return; sleep 0.2; done; }
check() { # name, wanted exit, actual exit, [grep pattern in out], [count pattern in log], [wanted count]
  local ok=1; [ "$2" = "$3" ] || { ok=0; echo "    exit $3, wanted $2"; }
  [ -z "${4:-}" ] || grep -q "$4" "$W/out" || { ok=0; echo "    output lacks: $4"; }
  [ -z "${5:-}" ] || [ "$(grep -c "$5" "$W/log")" = "$6" ] || { ok=0; echo "    log has $(grep -c "$5" "$W/log") x '$5', wanted $6"; }
  if [ $ok = 1 ]; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1"; sed 's/^/      | /' "$W/out" | tail -15; failn=$((failn+1)); fi; }

echo "add-r2-adapter-vars.sh"
start auto;   bash "$CI/add-r2-adapter-vars.sh" --apply >"$W/out" 2>&1; check "auto: waits for the deploy Render starts itself, no extra POST" 0 $? "Done. The deploy is live" "POST deploy" 0
start silent; bash "$CI/add-r2-adapter-vars.sh" --apply >"$W/out" 2>&1; check "silent: no deploy after the change -> starts one (the 2026-10-05 case)" 0 $? "starting one through the API" "POST deploy" 1
start fail;   bash "$CI/add-r2-adapter-vars.sh" --apply >"$W/out" 2>&1; check "fail: build_failed stops the script, exit 3" 3 $? "build_failed"
start never;  bash "$CI/add-r2-adapter-vars.sh" --apply >"$W/out" 2>&1; check "never: no deploy even after POST -> exit 3, one POST only" 3 $? "even after starting one" "POST deploy" 1
start late;   bash "$CI/add-r2-adapter-vars.sh" --apply >"$W/out" 2>&1; check "late: a second deploy queued behind the first is waited for" 0 $? "another deploy started behind it"
start silent; bash "$CI/add-r2-adapter-vars.sh" >"$W/out" 2>&1; check "dry run changes nothing and starts no deploy" 0 $? "Dry run" "PUT" 0

echo "enable-pipeline.sh"
start silent; bash "$CI/enable-pipeline.sh" --apply >"$W/out" 2>&1; check "silent: both flags set, each waits for its own new deploy" 0 $? "Done. Next" "POST deploy" 2
start auto;   bash "$CI/enable-pipeline.sh" --apply >"$W/out" 2>&1; check "auto: both flags set, no POST" 0 $? "Done. Next" "PUT" 2
start fail;   bash "$CI/enable-pipeline.sh" --apply >"$W/out" 2>&1; check "fail: stops after the first flag, second flag NOT set" 3 $? "build_failed" "PUT" 1
start auto;   bash "$CI/enable-pipeline.sh" >"$W/out" 2>&1; check "dry run changes nothing" 0 $? "Dry run" "PUT" 0
echo; echo "$pass passed, $failn failed"; [ "$failn" -eq 0 ]
