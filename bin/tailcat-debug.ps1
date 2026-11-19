<#
.SYNOPSIS
  Start a GitHub Actions debug session and SSH into the runner over tailcat,
  from Windows, leaving no files behind.

.DESCRIPTION
  Dispatches the debug workflow with a fresh one-off tailcat key, waits for
  the runner, and opens an SSH session to it. When you disconnect (or press
  Ctrl+C) it ends the session (or cancels the run) and deletes its temp
  folder, which held tailcat.exe, the one-off key and the downloaded address.
  Nothing else is written: tailcat's cache is redirected into that folder and
  ssh's known_hosts goes to NUL.

  Requires: gh (logged in; winget install GitHub.cli) and the Windows OpenSSH
  client (built into Windows 10 1809+ and 11).

.EXAMPLE
  & ([scriptblock]::Create((New-Object Net.WebClient).DownloadString('https://github.com/Sniperlyf3/PipelineTests/releases/latest/download/tailcat-debug.ps1'))) -Repo Sniperlyf3/PipelineTests

.EXAMPLE
  .\tailcat-debug.ps1 -Repo you/app -Workflow ci.yml -Ref my-branch -RunsOn windows-latest

.EXAMPLE
  .\tailcat-debug.ps1 -Repo you/app -- uname -a   # run one command instead of a shell
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  # OWNER/REPO. Default: the repo of the current directory (via gh).
  [string]$Repo,
  # Workflow file or name to dispatch.
  [string]$Workflow = 'debug.yml',
  # Branch or tag to run on. Default: the repo's default branch.
  [string]$Ref,
  # Runner label, passed as input runs_on.
  [string]$RunsOn,
  # Session length in minutes, passed as input timeout_minutes.
  [int]$Timeout = 0,
  # Extra workflow inputs, e.g. -Field foo=bar,baz=qux
  [string[]]$Field = @(),
  # SSH private key for the GitHub-SSH-key second factor (default: ssh's usual keys/agent).
  [string]$Identity,
  # Don't require one of your GitHub SSH keys (passes github_ssh_key=false).
  [switch]$NoGitHubSshKey,
  # Pick the session whose artifact name contains this text (matrix jobs).
  [string]$Job,
  # Input that receives the client key.
  [string]$KeyInput = 'tailcat_client_key',
  # Don't pass a session_id input; find the run by time and user instead.
  [switch]$NoSessionId,
  # Give up if no session appears within this many minutes.
  [int]$WaitTimeout = 20,
  # Remote command to run instead of an interactive shell (put it after --).
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$Command = @()
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$TailcatDebugVersion = 'dev'
$ArtifactPrefix = 'tailcat-address'

# All mutable state, in one hashtable: functions update its entries in place,
# which works the same whether this runs as a file, from the one-liner's
# script block (where $script: would mean the global scope) or dot-sourced.
$State = @{
  Work  = $null   # temp folder; everything we write lives here
  Tc    = $null   # path to tailcat.exe
  RunId = $null
  Addr  = $null
  Repo  = $Repo
}

function Write-Info([string]$m) { Write-Host "~ $m" -ForegroundColor Cyan }
function Write-Note([string]$m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Write-Warn([string]$m) { Write-Host "warning: $m" -ForegroundColor Yellow }

# Run a native command, capturing stdout+stderr as one string. Windows
# PowerShell 5.1 turns redirected stderr into errors, so relax that here.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $out = & $Exe @Arguments 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Out = (($out | Out-String).Trim()) }
}

function Invoke-GhJson([string[]]$Arguments) {
  $r = Invoke-Native gh $Arguments
  if ($r.Code -ne 0) { throw "gh $($Arguments -join ' ') failed: $($r.Out)" }
  if (-not $r.Out) { return $null }
  return ($r.Out | ConvertFrom-Json)
}

function New-WorkDir {
  $base = [IO.Path]::GetTempPath()
  # tailcat refuses these in the ssh ProxyCommand (cmd.exe would expand them).
  if ($base -match '[%!"]') {
    throw "Your temp path ($base) contains % ! or `". Set `$env:TMP to a plain folder (e.g. C:\Temp) and retry."
  }
  $State.Work = Join-Path $base ("tailcat-debug-" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $State.Work | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $State.Work 'cache') | Out-Null
}

function Install-Tailcat {
  $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'amd64' } 'ARM64' { 'arm64' }
    default { throw "unsupported CPU architecture: $env:PROCESSOR_ARCHITECTURE" }
  }
  $tag = (Invoke-GhJson @('api', 'repos/tailscale/tailcat/releases/latest')).tag_name
  if ($tag -notmatch '^v\d+\.\d+\.\d+') { throw "unexpected tailcat release tag: $tag" }
  $asset = "tailcat_$($tag.Substring(1))_windows_$arch.zip"
  Write-Note "fetching tailcat $tag (temporary)"
  $r = Invoke-Native gh @('release', 'download', $tag, '-R', 'tailscale/tailcat',
                          '-p', $asset, '-p', 'checksums.txt', '-D', $State.Work)
  if ($r.Code -ne 0) { throw "couldn't download tailcat: $($r.Out)" }
  $zip = Join-Path $State.Work $asset
  $want = Get-Content (Join-Path $State.Work 'checksums.txt') |
    Where-Object { ($_ -split '\s+')[1] -eq $asset } |
    ForEach-Object { ($_ -split '\s+')[0] } | Select-Object -First 1
  $got = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
  if (-not $want -or $want -ne $got) { throw "checksum mismatch for $asset" }
  Expand-Archive -Path $zip -DestinationPath (Join-Path $State.Work 'tc') -Force
  $exe = Get-ChildItem -Path (Join-Path $State.Work 'tc') -Recurse -Filter tailcat.exe | Select-Object -First 1
  if (-not $exe) { throw "tailcat.exe not found in $asset" }
  $State.Tc = $exe.FullName
}

# Run tailcat with its cache dir (%LOCALAPPDATA%\tailcat) redirected into the
# work folder. Don't capture the output of interactive calls: ssh needs the
# console. Read $LASTEXITCODE afterwards.
# Arguments go in as one array: as loose arguments, PowerShell would try to
# bind tailcat flags like --client to this function's own parameters.
function Invoke-Tailcat([string[]]$Arguments, [switch]$Quiet) {
  $saved = $env:LOCALAPPDATA
  $env:LOCALAPPDATA = Join-Path $State.Work 'cache'
  try {
    if ($Quiet) {
      $ErrorActionPreference = 'Continue'
      & $State.Tc @Arguments 2>$null
    } else {
      & $State.Tc @Arguments
    }
  } finally {
    $env:LOCALAPPDATA = $saved
  }
}

function New-ClientKey([string]$Path) {
  Invoke-Tailcat @('genkey', '--client', '--force', "--key=$Path") -Quiet | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'tailcat genkey failed' }
  $pub = ((Invoke-Tailcat @("--key=$Path", 'printpub') -Quiet) | Out-String).Trim()
  if ($pub -notmatch '^nodekey:[0-9a-f]{64}$') { throw "unexpected public key from tailcat: $pub" }
  return $pub
}

function Get-SshArgs {
  if ($Identity) { return @('-i', $Identity) }
  return @()
}

function Find-DispatchedRun([string]$Sid, [datetime]$Since, [string]$DispatchOut) {
  if ($DispatchOut -match '/actions/runs/(\d+)') { return $Matches[1] }
  $me = (Invoke-GhJson @('api', 'user')).login
  for ($i = 0; $i -lt 30; $i++) {
    $runs = Invoke-GhJson @('run', 'list', '-R', $State.Repo, '--workflow', $Workflow, '--event', 'workflow_dispatch',
                            '--user', $me, '-L', '20', '--json', 'databaseId,displayTitle,createdAt')
    $hit = @($runs | Where-Object {
      if ($Sid) { $_.displayTitle -like "*$Sid*" } else { ([datetime]$_.createdAt).ToUniversalTime() -ge $Since }
    } | Sort-Object { [datetime]$_.createdAt }) | Select-Object -First 1
    if ($hit) { return [string]$hit.databaseId }
    Start-Sleep -Seconds 2
  }
  return $null
}

function Wait-ForSession {
  $deadline = (Get-Date).AddMinutes($WaitTimeout)
  $last = ''
  while ($true) {
    $res = Invoke-GhJson @('api', "repos/$($State.Repo)/actions/runs/$($State.RunId)/artifacts?per_page=100")
    $names = @($res.artifacts | Where-Object { -not $_.expired -and $_.name.StartsWith($ArtifactPrefix) } |
               ForEach-Object { $_.name })
    if ($Job) { $names = @($names | Where-Object { $_.Contains($Job) }) }
    if ($names.Count -gt 0) {
      if ($names.Count -gt 1) {
        Write-Warn "run has $($names.Count) sessions; using $($names[0]) (pick one with -Job)"
      }
      return $names[0]
    }
    $run = Invoke-GhJson @('run', 'view', $State.RunId, '-R', $State.Repo, '--json', 'status,conclusion')
    $status = $run.status
    if ($run.conclusion) { $status += " ($($run.conclusion))" }
    if ($run.status -eq 'completed') {
      throw "run finished without a debug session: $status. Logs: gh run view $($State.RunId) -R $($State.Repo) --log-failed"
    }
    if ($status -ne $last) { Write-Note "run status: $status"; $last = $status }
    if ((Get-Date) -gt $deadline) { throw "no debug session after $WaitTimeout minutes (run status: $status)" }
    Start-Sleep -Seconds 4
  }
}

function Get-SessionAddress([string]$Artifact) {
  $dir = Join-Path $State.Work 'artifact'
  $r = Invoke-Native gh @('run', 'download', $State.RunId, '-R', $State.Repo, '-n', $Artifact, '-D', $dir)
  if ($r.Code -ne 0) { throw "couldn't download artifact ${Artifact}: $($r.Out)" }
  $file = Get-ChildItem -Path $dir -Recurse -File | Select-Object -First 1
  $addr = (Get-Content -Raw $file.FullName).Trim()
  if ($addr -notmatch '^tc[A-Za-z0-9_-]+$') { throw "artifact $Artifact doesn't hold a tailcat address" }
  return $addr
}

# End the session (or cancel the run if we never got in), then delete the
# work folder. Safe to call more than once.
function Stop-DebugSession([string]$Key) {
  if ($State.RunId) {
    $ended = $false
    if ($State.Addr -and $State.Tc -and (Test-Path $Key)) {
      Write-Info 'Ending debug session; the job will continue'
      $a = @("--key=$Key", 'ssh') + @(Get-SshArgs) + @($State.Addr, 'touch ~/.tailcat-debug/continue')
      # Not -Quiet: ssh may need to ask for your SSH key's passphrase.
      Invoke-Tailcat $a | Out-Null
      $ended = ($LASTEXITCODE -eq 0)
    }
    if (-not $ended) {
      Write-Info "Cancelling run $($State.RunId) (the one-off key is being deleted, so nobody could connect to it)"
      $r = Invoke-Native gh @('run', 'cancel', $State.RunId, '-R', $State.Repo)
      if ($r.Code -ne 0) { Write-Warn "couldn't cancel the run: $($r.Out)" }
    }
    $State.RunId = $null
  }
  Remove-WorkDir
}

function Remove-WorkDir {
  if (-not $State.Work -or -not (Test-Path $State.Work)) { return }
  # A ProxyCommand tailcat.exe can outlive ssh for a moment and lock the file.
  # Match on the folder's unique name: the temp path may be in 8.3 short form
  # (C:\Users\RUNNER~1\...) while process paths are always long.
  $leaf = '*\' + (Split-Path -Leaf $State.Work) + '\*'
  Get-Process -Name tailcat -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -and $_.Path -like $leaf } |
    Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 10 -and (Test-Path $State.Work); $i++) {
    Remove-Item -Recurse -Force -Path $State.Work -ErrorAction SilentlyContinue
    if (Test-Path $State.Work) { Start-Sleep -Milliseconds 500 }
  }
  if (Test-Path $State.Work) { Write-Warn "couldn't fully delete $($State.Work); remove it by hand" }
  else { Write-Note 'temp files removed' }
  $State.Work = $null
}

function Start-DebugSession {
  foreach ($cmd in 'gh', 'ssh') {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
      if ($cmd -eq 'gh') { throw 'gh is required: winget install GitHub.cli, then gh auth login' }
      throw 'ssh is required: Settings > System > Optional features > OpenSSH Client'
    }
  }
  if ((Invoke-Native gh @('auth', 'status')).Code -ne 0) { throw "gh isn't logged in; run: gh auth login" }
  if ($Identity -and -not (Test-Path $Identity)) { throw "no such SSH key file: $Identity" }
  if (-not $State.Repo) {
    $State.Repo = (Invoke-GhJson @('repo', 'view', '--json', 'nameWithOwner')).nameWithOwner
    if (-not $State.Repo) { throw "can't tell which repository to use; pass -Repo OWNER/REPO" }
  }

  $fields = @()
  foreach ($f in $Field) { $fields += @('-f', $f) }
  if ($RunsOn) { $fields += @('-f', "runs_on=$RunsOn") }
  if ($Timeout -gt 0) { $fields += @('-f', "timeout_minutes=$Timeout") }
  if ($NoGitHubSshKey) {
    $fields += @('-f', 'github_ssh_key=false')
  } else {
    $me = (Invoke-GhJson @('api', 'user')).login
    $keys = @(Invoke-GhJson @('api', "users/$me/keys"))
    if ($keys.Count -eq 0) {
      Write-Warn "your GitHub account ($me) has no SSH keys, so debug.yml's default second factor can't be met."
      Write-Warn 'Add one (gh ssh-key add $HOME\.ssh\id_ed25519.pub) or pass -NoGitHubSshKey.'
    }
  }

  $key = $null
  try {
    New-WorkDir
    Install-Tailcat
    $key = Join-Path $State.Work 'client.private.json'
    $pub = New-ClientKey $key

    $sid = ''
    if (-not $NoSessionId) { $sid = [guid]::NewGuid().ToString('N').Substring(0, 12) }
    $dispatch = @('workflow', 'run', $Workflow, '-R', $State.Repo, '-f', "$KeyInput=$pub")
    if ($Ref) { $dispatch += @('--ref', $Ref) }
    if ($sid) { $dispatch += @('-f', "session_id=$sid") }
    $dispatch += $fields

    $since = (Get-Date).ToUniversalTime().AddSeconds(-30)
    Write-Info "Dispatching $Workflow on $($State.Repo)$(if ($Ref) { " @ $Ref" })"
    $r = Invoke-Native gh $dispatch
    if ($r.Code -ne 0) { throw "gh workflow run failed: $($r.Out)" }
    $State.RunId = Find-DispatchedRun $sid $since $r.Out
    if (-not $State.RunId) { throw "dispatched, but couldn't find the run; cancel it in the Actions tab if it started" }
    Write-Note "run: https://github.com/$($State.Repo)/actions/runs/$($State.RunId)"

    Write-Info 'Waiting for the runner to start the session...'
    $artifact = Wait-ForSession
    $State.Addr = Get-SessionAddress $artifact

    Write-Info "Connecting to runner (run $($State.RunId), $artifact)"
    Write-Note 'Exit the shell when done; the session is ended and temp files are removed.'
    Invoke-Tailcat (@("--key=$key", 'ssh') + @(Get-SshArgs) + @($State.Addr) + @($Command))
    if ($LASTEXITCODE -eq 255) {
      Write-Warn "ssh failed. If the session requires your GitHub SSH key (debug.yml's default), make sure"
      Write-Warn 'ssh can use one listed at https://github.com/<you>.keys (ssh-agent, or -Identity <key>), or use -NoGitHubSshKey.'
    }
  } finally {
    Stop-DebugSession $key
  }
}

# Dot-sourcing (". .\tailcat-debug.ps1") only loads the functions, for tests.
if ($MyInvocation.InvocationName -ne '.') {
  Write-Host "tailcat-debug $TailcatDebugVersion (Windows)" -ForegroundColor DarkGray
  Start-DebugSession
}
