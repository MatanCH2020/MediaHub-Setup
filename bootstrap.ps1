# ============================================================
#  MediaHub bootstrap
#
#  This is the only public part of MediaHub. It contains no application code -
#  its whole job is to check the activation key, get the user signed in to
#  GitHub, fetch the private repository and hand over to install.ps1.
#
#  Run:
#    irm https://raw.githubusercontent.com/MatanCH2020/MediaHub-Setup/main/bootstrap.ps1 | iex
#
#  ASCII only, on purpose. This file is piped straight into iex from a web
#  request, where the encoding of the response is out of our hands and a
#  mangled non-ASCII character becomes a parse error with no useful message.
#  The installer it hands off to is English and ASCII for the same reason.
# ============================================================

$ErrorActionPreference = 'Stop'

# Printed in the banner. Bumped by hand on every change to this file, so a
# screenshot always says which copy ran - raw.githubusercontent caches for
# minutes and there is otherwise no way to tell a stale run from a current one.
$BUILD      = '2026-08-17.3'

$OWNER      = 'MatanCH2020'
$REPO       = 'MediaHub-Windows'
$ALLOW_URL  = 'https://raw.githubusercontent.com/MatanCH2020/MediaHub-Setup/main/allow.json'
$INSTALL_TO = Join-Path $env:LOCALAPPDATA 'MediaHub'

function Line($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Step($n, $text) { Write-Host "`n[$n] $text" -ForegroundColor Cyan }

# Runs an external program and returns its exit code, without letting its
# stderr abort this script.
#
# PowerShell 5.1 wraps every stderr line from a native executable in an
# ErrorRecord once that stream is redirected, and with
# $ErrorActionPreference = 'Stop' that becomes a TERMINATING error even when
# the program exited 0. `gh auth status` writes its normal "not logged in"
# message to stderr, so it was killing this script at the exact line that
# should have started the sign-in. Relaxing the preference around the call is
# the only reliable fix - `2>$null` and `| Out-Null` do not prevent it.
function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $Exe @Arguments 2>&1
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($out | Out-String)
        }
    } catch {
        return [pscustomobject]@{ ExitCode = 1; Output = $_.Exception.Message }
    } finally {
        $ErrorActionPreference = $prev
    }
}

Write-Host ''
Write-Host "  MediaHub - setup    (bootstrap $BUILD)" -ForegroundColor White
Write-Host '  ----------------------------------------' -ForegroundColor DarkGray

# ---- 1. activation key -----------------------------------------------
# Checked here as well as in the running app: failing before anything is
# downloaded or installed is a much better experience than failing after.
Step 1 'Activation key'

# Accepts what people actually type: lower case, missing or wrong dashes,
# stray spaces, a trailing paste artefact. Everything that is not a letter or
# digit is dropped and the canonical dashes are put back, so MHW5p9q3qzn262g
# and "mhw-5p9q 3qzn-262g" both resolve to the same key.
function Format-Key($raw) {
    $clean = ($raw -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
    if ($clean.Length -eq 15 -and $clean.StartsWith('MHW')) {
        return 'MHW-' + $clean.Substring(3, 4) + '-' + $clean.Substring(7, 4) + '-' + $clean.Substring(11, 4)
    }
    return $raw.Trim().ToUpperInvariant()
}


# Characters people genuinely mix up when reading a key off a screen or hearing
# it over the phone. The alphabet these keys were minted from excludes I, O, 0
# and 1 but kept every one of these pairs, which was a mistake - MHW-5P9Q-3QZN-262G
# contains all three.
#
# Rather than reissue every key, a rejected entry is retried with each plausible
# substitution. The keyspace is 32^12, so a handful of extra candidates is not a
# meaningful weakening; a wrong key is still a wrong key.
$CONFUSABLE = @{
    '2' = 'Z'; 'Z' = '2'
    '5' = 'S'; 'S' = '5'
    '6' = 'G'; 'G' = '6'
    '8' = 'B'; 'B' = '8'
}

# Every combination of "leave it" / "swap it" across the ambiguous positions.
# Capped so a pathological input cannot blow up into thousands of hashes.
function Get-KeyVariants($key) {
    $variants = New-Object System.Collections.Generic.List[string]
    $variants.Add($key)
    foreach ($i in 0..($key.Length - 1)) {
        $c = $key[$i].ToString()
        if (-not $CONFUSABLE.ContainsKey($c)) { continue }
        $swapped = New-Object System.Collections.Generic.List[string]
        foreach ($v in $variants) {
            $alt = $v.Substring(0, $i) + $CONFUSABLE[$c] + $v.Substring($i + 1)
            $swapped.Add($alt)
        }
        foreach ($s in $swapped) { if ($variants.Count -lt 128) { $variants.Add($s) } }
    }
    return $variants
}

function Get-KeyHash($key) {
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($key)
    return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
}

# Fetched as text and parsed here rather than with Invoke-RestMethod, so a
# byte-order mark can be stripped first: ConvertFrom-Json rejects a leading
# U+FEFF with "Invalid JSON primitive", and raw.githubusercontent can serve a
# cached copy for a few minutes after the file itself has been fixed.
try {
    $body  = (Invoke-WebRequest -Uri $ALLOW_URL -TimeoutSec 30 -UseBasicParsing).Content
    $allow = $body.TrimStart([char]0xFEFF) | ConvertFrom-Json
} catch {
    Line "    Could not reach the key list: $($_.Exception.Message)" 'Red'
    Line '    Check the internet connection and try again.' 'Yellow'
    return
}

# Three attempts before giving up. A single mistyped character used to end the
# whole run and force the one-liner to be pasted again - a bad first minute for
# something whose very first step is copying a 16-character code by hand.
$info = $null
$key  = $null
for ($attempt = 1; $attempt -le 3 -and -not $info; $attempt++) {
    $typed = Read-Host '    Enter your key (MHW-XXXX-XXXX-XXXX)'
    if (-not $typed) { Line '    No key entered. Stopping.' 'Red'; return }

    $key   = Format-Key $typed
    $entry = $null
    $matched = $key
    foreach ($candidate in (Get-KeyVariants $key)) {
        $hit = $allow.keys.PSObject.Properties | Where-Object { $_.Name -eq (Get-KeyHash $candidate) }
        if ($hit) { $entry = $hit; $matched = $candidate; break }
    }
    if ($entry -and $matched -ne $key) {
        Line "    (read '$key' as '$matched' - 2/Z, 5/S and 6/G look alike)" 'DarkGray'
        $key = $matched
    }

    if ($entry) {
        $candidate = $entry.Value
        if ($candidate.expires -and ([datetime]$candidate.expires) -lt (Get-Date)) {
            Line "    That key expired on $($candidate.expires). Ask Matan for a new one." 'Red'
            return
        }
        $info = $candidate
    } elseif ($attempt -lt 3) {
        Line "    Not recognised - check for a typo. Attempt $attempt of 3." 'Yellow'
        Line "    (read as: $key)" 'DarkGray'
    } else {
        Line '    That key is not recognised. Ask Matan for a key.' 'Red'
        return
    }
}

Line "    OK - key accepted ($($info.label))" 'Green'

# ---- 2. GitHub CLI ----------------------------------------------------
# The repository is private, so the download needs a real GitHub identity.
# That identity is the access control: Matan invites a specific account, and
# removing it cuts off updates. gh handles the browser login flow for us.
Step 2 'GitHub sign-in'

$gh = (Get-Command gh.exe -ErrorAction SilentlyContinue).Source
if (-not $gh) {
    Line '    Installing the GitHub CLI (one time)...' 'Gray'
    $null = Invoke-Native 'winget' @('install', '--id', 'GitHub.cli', '--exact', '--silent',
                                     '--accept-package-agreements', '--accept-source-agreements')
    # winget updates PATH for new processes, not for this one.
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
    $gh = (Get-Command gh.exe -ErrorAction SilentlyContinue).Source
    if (-not $gh) {
        Line '    gh was installed but is not on PATH yet.' 'Yellow'
        Line '    Close this window, open a new PowerShell, and run the same command again.' 'Yellow'
        return
    }
}

$status = Invoke-Native $gh @('auth', 'status')
if ($status.ExitCode -ne 0) {
    Line '    Not signed in. A browser window will open.' 'Gray'
    # NOT wrapped: this one is interactive and its output has to reach the
    # console, including the one-time code the user has to type.
    & $gh auth login --hostname github.com --git-protocol https --web
    $status = Invoke-Native $gh @('auth', 'status')
    if ($status.ExitCode -ne 0) { Line '    Sign-in did not complete. Stopping.' 'Red'; return }
}

$who = (Invoke-Native $gh @('api', 'user', '--jq', '.login')).Output.Trim()
Line "    OK - signed in as $who" 'Green'

# ---- 3. access ---------------------------------------------------------
# Checked on its own, BEFORE looking at the disk. Deciding this by whether the
# clone succeeded meant an existing folder skipped the check entirely: a
# never-authorised account found the repo already there, took the "update"
# path, had its silent sync fail, and was told OK. That is the access gate not
# running at all, and it also left the copy on disk permanently stale.
Step 3 'Checking access'

$access = Invoke-Native $gh @('api', "repos/$OWNER/$REPO", '--jq', '.full_name')
if ($access.ExitCode -ne 0) {
    Line "    The account '$who' has a valid key but no access to the code." 'Red'
    Line '    A key and a GitHub invitation are both required.' 'Yellow'
    Line ''
    Line '    Ask Matan to run:' 'DarkGray'
    Line "      gh repo add-collaborator $OWNER/$REPO $who" 'DarkGray'
    Line ''
    if (Test-Path (Join-Path $INSTALL_TO '.git')) {
        Line "    Note: an earlier copy is still on this machine at" 'Yellow'
        Line "      $INSTALL_TO" 'DarkGray'
        Line '    It cannot be updated without access, so it is left untouched.' 'Yellow'
    }
    return
}
Line "    OK - $who can reach $OWNER/$REPO" 'Green'

# ---- 4. fetch ---------------------------------------------------------
Step 4 'Downloading MediaHub'

if (Test-Path (Join-Path $INSTALL_TO '.git')) {
    Line "    Already present - updating." 'Gray'
    Push-Location $INSTALL_TO
    try {
        # Fetch and hard-reset rather than pull: a stale copy is worth less than
        # a correct one, and a merge conflict here would leave a half-updated
        # install that is harder to diagnose than a clean overwrite.
        $fetch = Invoke-Native 'git' @('fetch', 'origin', 'main')
        if ($fetch.ExitCode -ne 0) {
            Line "    Could not fetch: $($fetch.Output.Trim())" 'Red'
            Pop-Location
            return
        }
        $null = Invoke-Native 'git' @('reset', '--hard', 'origin/main')
        $head = (Invoke-Native 'git' @('rev-parse', '--short', 'HEAD')).Output.Trim()
        Line "    OK - updated to $head" 'Green'
    } finally { Pop-Location }
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $INSTALL_TO) | Out-Null
    $clone = Invoke-Native $gh @('repo', 'clone', "$OWNER/$REPO", $INSTALL_TO)
    if ($clone.ExitCode -ne 0) {
        Line '    Could not download the repository.' 'Red'
        Line "    $($clone.Output.Trim())" 'DarkGray'
        return
    }
    Push-Location $INSTALL_TO
    $head = (Invoke-Native 'git' @('rev-parse', '--short', 'HEAD')).Output.Trim()
    Pop-Location
    Line "    OK - $INSTALL_TO ($head)" 'Green'
}

# ---- 5. hand off ------------------------------------------------------
Step 5 'Starting the installer'

# The key is passed through so the installer does not ask a second time, and
# so it can record which key this machine was activated with.
$installer = Join-Path $INSTALL_TO 'install.ps1'
if (-not (Test-Path $installer)) { Line "    Missing: $installer" 'Red'; return }

Line '    The installer needs administrator rights and opens in a new window.' 'Gray'
Line '    Approve the prompt, then follow it there - this window is done.' 'Gray'
Line ''

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Key $key
