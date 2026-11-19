#!/usr/bin/env bash
# Keeps the job alive while the debug session is open.
# Ends when: $state/continue exists, the timeout elapses, or the server dies.
#
# Env: TC_STATE_DIR, TC_TIMEOUT_MINUTES (default 30)
set -euo pipefail

state="${TC_STATE_DIR:-$HOME/.tailcat-debug}"
timeout_min="${TC_TIMEOUT_MINUTES:-30}"
[[ "$timeout_min" =~ ^[0-9]+$ ]] || { echo "::error::timeout-minutes must be an integer"; exit 1; }
pid=$(cat "$state/pid")
deadline=$(( $(date +%s) + timeout_min * 60 ))

echo "Debug session open for up to ${timeout_min} minutes."
echo "Connect: tailcat-debug attach ${GITHUB_RUN_ID:-<run-id>} -R ${GITHUB_REPOSITORY:-<repo>}"
echo "End it from inside the session with: tailcat-debug-done   (or touch $state/continue)"

last_report=0
while :; do
  now=$(date +%s)
  if [[ -e "$state/continue" ]]; then
    echo "Continue requested; ending debug session."
    break
  fi
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "::warning::tailcat server exited"
    tail -n 50 "$state/server.log" || true
    break
  fi
  if (( now >= deadline )); then
    echo "Timeout of ${timeout_min} minutes reached; ending debug session."
    break
  fi
  if (( now - last_report >= 60 )); then
    echo "[$(date -u +%H:%M:%S)] session open, $(( (deadline - now + 59) / 60 )) min left"
    last_report=$now
  fi
  sleep 5
done

kill "$pid" 2>/dev/null || true

# Undo the login-shell hook added by start-server.sh (matters on self-hosted runners).
if [[ -f "$state/hooked-files" ]]; then
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    grep -vF '# tailcat-debug' "$f" > "$f.tc-tmp" || true
    cat "$f.tc-tmp" > "$f" && rm -f "$f.tc-tmp"
  done < "$state/hooked-files"
fi

if [[ -e "$state/fail" ]]; then
  echo "::error::Job failed from the debug session (tailcat-debug-fail)."
  exit 1
fi
