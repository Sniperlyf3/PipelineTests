# PipelineTests: SSH into GitHub Actions runners with tailcat

Get a shell on a GitHub Actions runner with one command:

```bash
tailcat-debug run -R Sniperlyf3/PipelineTests
```

This dispatches a workflow, waits for the runner to start, and drops you into an
SSH session on it. The connection goes over [tailcat](https://github.com/tailscale/tailcat),
which uses Tailscale's WireGuard data plane without the Tailscale control plane. You
don't need a Tailscale account, inbound ports, or secrets in the repo.

## How it works

```
your machine                                         GitHub-hosted runner
────────────                                         ────────────────────
tailcat-debug run
 ├─ tailcat genkey --client  → one-off client key (private part never leaves your machine)
 ├─ gh workflow run debug.yml -f tailcat_client_key=nodekey:…  ─────►  tailcat serve --allow=nodekey:… no-auth-ssh
 │                                                                     │  (fresh ephemeral server key)
 ├─ polls the run for the "tailcat-address-*" artifact  ◄──────────────┘  uploads its address as an artifact
 └─ tailcat --key=<one-off> ssh <address>   ═══ WireGuard (direct, or via DERP) ═══►  shell in $GITHUB_WORKSPACE
```

- **Keys.** Each session uses a fresh server key on the runner and a fresh client key
  on your machine. The runner passes `--allow` so it only accepts WireGuard handshakes
  from your client key. Anyone else's packets are dropped before SSH sees them. That's
  why the address can be published as a workflow artifact: without your private key
  it gets nobody in.
- **The shell looks like a step.** The session starts in `$GITHUB_WORKSPACE` with the
  job's environment: `PATH`, `GITHUB_*`, and whatever the earlier steps exported.
- **Ending the session.** Run `tailcat-debug-done` inside the session to let the job
  continue, or `tailcat-debug-fail` to fail it. When you disconnect, the helper asks
  whether to end the session. If you do nothing, it ends at `timeout-minutes` (default 30).

## Install the helper

Download it from [Releases](https://github.com/Sniperlyf3/PipelineTests/releases/latest):

```bash
mkdir -p ~/.local/bin && curl -fsSL https://github.com/Sniperlyf3/PipelineTests/releases/latest/download/tailcat-debug -o ~/.local/bin/tailcat-debug && chmod +x ~/.local/bin/tailcat-debug
```

It needs [`gh`](https://cli.github.com) (logged in, with permission to run workflows on
the repo) and `ssh`. If `tailcat` is missing, the helper offers to install it: Linux
gets the checksum-verified release binary, macOS gets `brew install tailcat`. It runs on
Linux, macOS (it's written to work with the stock bash 3.2), and Git Bash or WSL on Windows.

## Usage

### Debug on a fresh runner

```bash
tailcat-debug run -R Sniperlyf3/PipelineTests                       # ubuntu-latest
tailcat-debug run -R Sniperlyf3/PipelineTests --runs-on macos-latest --timeout 60
tailcat-debug run -R Sniperlyf3/PipelineTests -- uname -a           # run one command
```

`run` options: `-w/--workflow`, `-r/--ref`, `-f key=value` (extra workflow inputs),
`--keep`/`--end` (what to do after you disconnect), `--wait-timeout`. See
`tailcat-debug help`.

### Debug your own pipeline

Add the action to the workflow you want to debug, and give `workflow_dispatch` a
`tailcat_client_key` input. `tailcat-debug run -w ci.yml` then fills that input.

```yaml
on:
  push:
  workflow_dispatch:
    inputs:
      tailcat_client_key: { type: string, required: false, default: "" }
      session_id:         { type: string, required: false, default: "" }

run-name: ${{ inputs.session_id && format('debug session {0}', inputs.session_id) || github.event.head_commit.message || github.event.pull_request.title || github.workflow }}

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: make build

      # Only runs when you start the workflow with tailcat-debug.
      - uses: Sniperlyf3/PipelineTests@v1
        if: inputs.tailcat_client_key != ''
        with:
          allow: ${{ inputs.tailcat_client_key }}

      - run: make test
```

```bash
tailcat-debug run -R you/your-repo -w ci.yml -r my-branch
```

The `session_id` input and `run-name` let the helper find exactly the run it started.
If your workflow can't have them, pass `--no-session-id` and the helper picks your
newest dispatched run instead.

You can also call the ready-made workflow from your repo instead:
`uses: Sniperlyf3/PipelineTests/.github/workflows/debug.yml@main` (example at the top
of [`debug.yml`](.github/workflows/debug.yml)).

### Debug a job when it fails

For runs you didn't start with the helper (pushes, PRs), use a long-lived client key:

```bash
tailcat-debug pubkey     # creates ~/.config/tailcat-debug/client.private.json, prints nodekey:…
```

Store the printed key in a repo variable, e.g. `TAILCAT_ALLOW`. Several people can be
listed, comma-separated. It's a public key, so it doesn't need to be a secret.

```yaml
      - uses: Sniperlyf3/PipelineTests@v1
        if: failure()
        with:
          allow: ${{ vars.TAILCAT_ALLOW }}
```

Then connect to the run:

```bash
tailcat-debug attach https://github.com/you/your-repo/actions/runs/123456789
```

If a run has several sessions (matrix jobs), `attach` asks which one to use, or you
can pick with `--job <text>`.

## Action reference

`uses: Sniperlyf3/PipelineTests@v1`

| input | default | |
|---|---|---|
| `allow` | | Comma-separated client public keys (`nodekey:…`) allowed to connect. |
| `ssh-authorized-keys` | | Optional second factor at the SSH layer, e.g. `${{ github.actor }}@github` (fetches the actor's GitHub SSH keys). If set, the session uses tailcat's `ssh` service instead of `no-auth-ssh`. |
| `insecure-no-auth` | `false` | Start even with neither of the above. Then anyone who can read the repo's artifacts gets a shell. |
| `wait` | `true` | Block until `tailcat-debug-done`, the timeout, or server exit. With `false` the server runs in the background for the rest of the job. |
| `timeout-minutes` | `30` | Maximum session length when `wait` is true. |
| `artifact-name` | unique per job | Must start with `tailcat-address`. |
| `tailcat-version` | `latest` | tailcat release tag to install. |

Outputs: `artifact-name`, `address-file`.

Supported runners: Linux x64/arm64 and macOS. Windows runners should work, but the
shell there is tailcat's Windows SSH shell, and the environment and cwd setup
described above doesn't apply.

## Releasing

Push a tag like `v1.0.0`. The [release workflow](.github/workflows/release.yml)
publishes a release with `tailcat-debug` (version stamped in) and `SHA256SUMS`
attached, and moves the `v1` tag.

## Repo layout

```
action.yml                   composite action: install → start server → publish address → wait
scripts/install-tailcat.sh   installs tailcat on the runner (checksum-verified)
scripts/start-server.sh      starts tailcat serve --allow=… in the background
scripts/wait.sh              keeps the job alive until done/timeout
bin/tailcat-debug            the helper you run locally (shipped in Releases)
.github/workflows/debug.yml  dispatchable/reusable "give me a runner" workflow
.github/workflows/test.yml   lint and a real end-to-end session test on Linux + macOS
.github/workflows/release.yml
```
