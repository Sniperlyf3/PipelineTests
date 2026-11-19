#!/usr/bin/env bash
# Starts a tailcat SSH server in the background on the runner and writes its
# address to $TC_STATE_DIR/address (later uploaded as an artifact).
#
# Env (set by action.yml):
#   TC_ALLOW          comma-separated client node keys (nodekey:<hex>) allowed to connect
#   TC_SSH_KEYS       optional --ssh-authorized-keys sources (e.g. "alice@github")
#   TC_ALLOWED_ACTORS comma-separated GitHub users allowed to start a session ("*" = anyone)
#   TC_INSECURE       "true" to allow an unauthenticated server (address == credential)
#   TC_ARTIFACT_NAME  artifact name to publish the address under (optional)
#   TC_SERVER_KEY     optional server private key JSON (from tailcat genkey) for a
#                     fixed address you already know; otherwise a fresh one per run
set -euo pipefail

state="${TC_STATE_DIR:-$HOME/.tailcat-debug}"
mkdir -p "$state"
chmod 700 "$state"
rm -f "$state/address" "$state/continue" "$state/fail"

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Who may open a session at all. Checked against both the run's actor and the
# user who triggered this attempt (a re-run), case-insensitively.
# Empty (e.g. an unset repo variable) means the repo owner, never "anyone".
actors="${TC_ALLOWED_ACTORS:-}"; actors="${actors//[[:space:]]/}"
actors="$(lower "${actors:-${GITHUB_REPOSITORY_OWNER:-}}")"
[[ -n "$actors" ]] || { echo "::error::allowed-actors is empty and the repository owner is unknown"; exit 1; }
if [[ "$actors" != "*" ]]; then
  for who in "${GITHUB_ACTOR:-}" "${GITHUB_TRIGGERING_ACTOR:-${GITHUB_ACTOR:-}}"; do
    if [[ ",$actors," != *",$(lower "$who"),"* ]]; then
      echo "::error::'$who' is not in allowed-actors ($actors); not starting a debug session."
      exit 1
    fi
  done
fi

allow="${TC_ALLOW:-}"
allow="${allow//[[:space:]]/}"   # tolerate "key1, key2" and trailing newlines
ssh_keys="${TC_SSH_KEYS:-}"

if [[ -n "$allow" ]]; then
  IFS=, read -r -a keys <<< "$allow"
  allow=""
  for k in "${keys[@]}"; do
    [[ -z "$k" ]] && continue
    [[ "$k" =~ ^nodekey:[0-9a-f]{64}$ ]] || { echo "::error::invalid client key in 'allow': $k (want nodekey:<64 hex chars>)"; exit 1; }
    allow="${allow:+$allow,}$k"
  done
fi

if [[ -z "$allow" && -z "$ssh_keys" && "${TC_INSECURE:-false}" != true ]]; then
  cat <<'MSG'
::error::No access control configured. Set the 'allow' input to your tailcat client key
(tailcat-debug prints it with: tailcat-debug pubkey), and/or 'ssh-authorized-keys'
(e.g. "${{ github.actor }}@github"). The server address is published as a workflow
artifact, so without one of these anyone who can read this repo's artifacts could
get a shell. Set 'insecure-no-auth: true' only if you really want that.
MSG
  exit 1
fi

# Snapshot the step's environment so the SSH shell (which tailcat starts with a
# minimal env in $HOME) looks like a normal step: same PATH, GITHUB_* vars, cwd.
{
  while IFS= read -r name; do
    case "$name" in
      PWD|OLDPWD|SHLVL|_|HOME|USER|SHELL|TERM|BASH*|TC_*|INPUT_*) continue ;;
    esac
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    printf 'export %s=%q\n' "$name" "${!name}"
  done < <(compgen -e)
  printf 'export TAILCAT_DEBUG_DIR=%q\n' "$state"
} > "$state/env"
chmod 600 "$state/env"

cat > "$state/rc" <<RC
# Added by tailcat-debug: make the SSH shell look like the job's step environment.
[ -f "$state/env" ] && . "$state/env"
cd "${GITHUB_WORKSPACE:-$HOME}" 2>/dev/null || true
tailcat-debug-done() { touch "$state/continue"; echo "Job will continue. You can disconnect."; }
tailcat-debug-fail() { touch "$state/fail" "$state/continue"; echo "Job will be failed. You can disconnect."; }
if [ -n "\$PS1" ] && [ -z "\$TAILCAT_DEBUG_BANNER_SHOWN" ]; then
  export TAILCAT_DEBUG_BANNER_SHOWN=1
  echo "tailcat debug session on \$(hostname) — job: \${GITHUB_JOB:-?}, run: \${GITHUB_SERVER_URL:-}/\${GITHUB_REPOSITORY:-}/actions/runs/\${GITHUB_RUN_ID:-}"
  echo "Run 'tailcat-debug-done' to let the job continue, 'tailcat-debug-fail' to fail it."
fi
RC

# Hook rc into the login shell tailcat starts for interactive sessions
# (bash -l / zsh -l). wait.sh removes the hook again when the session ends.
hook=". \"$state/rc\" # tailcat-debug"
login_file="$HOME/.bash_profile"
for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
  [[ -f "$f" ]] && { login_file="$f"; break; }
done
hooked=("$login_file")
[[ "$(uname -s)" == Darwin ]] && hooked+=("$HOME/.zprofile")
for f in "${hooked[@]}"; do
  grep -qsF "$hook" "$f" || printf '\n%s\n' "$hook" >> "$f"
done
printf '%s\n' "${hooked[@]}" > "$state/hooked-files"

# Server key: a fixed one from a secret (address known in advance, so you can
# connect with plain `tailcat ssh <address>`), or a fresh ephemeral one.
key_arg=--key=new
key_file=""
if [[ -n "${TC_SERVER_KEY:-}" ]]; then
  key_file="$state/server.private.json"
  ( umask 077; printf '%s' "$TC_SERVER_KEY" > "$key_file" )
  key_arg="--key=$key_file"
fi

args=("$key_arg" serve --full-address)
[[ -n "$allow" ]] && args+=("--allow=$allow")
if [[ -n "$ssh_keys" ]]; then
  args+=("--ssh-authorized-keys=$ssh_keys" ssh)
else
  args+=(no-auth-ssh)
fi

cd "$HOME"
echo "Starting: tailcat ${args[*]}"
TAILCAT_ADDR_FILE="$state/address" nohup tailcat "${args[@]}" > "$state/server.log" 2>&1 < /dev/null &
pid=$!
echo "$pid" > "$state/pid"
[[ -n "$key_file" ]] && trap 'rm -f "$key_file"' EXIT

for _ in $(seq 1 120); do
  [[ -s "$state/address" ]] && break
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "::error::tailcat server exited during startup"
    cat "$state/server.log"
    exit 1
  fi
  sleep 0.5
done
[[ -s "$state/address" ]] || { echo "::error::timed out waiting for tailcat address"; cat "$state/server.log"; exit 1; }
# tailcat has read the key by now; don't leave the private key on disk.
[[ -n "$key_file" ]] && rm -f "$key_file"

addr=$(tr -d '[:space:]' < "$state/address")
name="${TC_ARTIFACT_NAME:-}"
if [[ -z "$name" ]]; then
  # Unique per job so matrix jobs don't collide; the helper matches the prefix.
  name="tailcat-address-${GITHUB_JOB:-job}-${RUNNER_OS:-os}-${RANDOM}${RANDOM}"
fi

# Copy outside the hidden state dir: upload-artifact skips hidden paths.
pub_dir="${RUNNER_TEMP:-$state}/tailcat-address"
mkdir -p "$pub_dir"
printf '%s\n' "$addr" > "$pub_dir/address.txt"

{
  echo "artifact-name=$name"
  echo "address-file=$pub_dir/address.txt"
  echo "state-dir=$state"
} >> "${GITHUB_OUTPUT:-/dev/null}"

repo_run="${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}"
if [[ -n "$allow" || -n "$ssh_keys" ]]; then
  # Access is enforced by key, so the address itself is not the credential.
  # The address isn't the credential, but there's no need to put it in
  # (possibly public) logs either; it's only in the artifact.
  if [[ -n "$key_file" ]]; then
    connect_cmd="tailcat ssh <your saved address>"
  else
    connect_cmd="tailcat-debug attach ${GITHUB_RUN_ID:-<run-id>} -R ${GITHUB_REPOSITORY:-<repo>}"
  fi
  echo "::notice title=tailcat debug session::Connect with: $connect_cmd"
else
  echo "::warning title=tailcat debug session::Running WITHOUT authentication; the address artifact '$name' is the only credential."
fi

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat >> "$GITHUB_STEP_SUMMARY" <<SUM
### 🐈 tailcat debug session

Connect from your machine:

\`\`\`bash
${connect_cmd:-tailcat-debug attach ${GITHUB_RUN_ID:-} -R ${GITHUB_REPOSITORY:-}}
\`\`\`

Inside the session run \`tailcat-debug-done\` to let the job continue (or \`tailcat-debug-fail\` to fail it).
Address artifact: \`$name\` · run: ${GITHUB_SERVER_URL:-https://github.com}/$repo_run
SUM
fi
