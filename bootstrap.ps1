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
#  The installer it hands off to is UTF-8 with a BOM and prints in Hebrew.
# ============================================================

$ErrorActionPreference = 'Stop'

$OWNER      = 'MatanCH2020'
$REPO       = 'MediaHub-Windows'
$ALLOW_URL  = 'https://raw.githubusercontent.com/MatanCH2020/MediaHub-Setup/main/allow.json'
$INSTALL_TO = Join-Path $env:LOCALAPPDATA 'MediaHub'

function Line($text, $color = 'Gray') { Write-Host $text -ForegroundColor $color }
function Step($n, $text) { Write-Host "`n[$n] $text" -ForegroundColor Cyan }

Write-Host ''
Write-Host '  MediaHub - setup / התקנה' -ForegroundColor White
Write-Host '  ------------------------' -ForegroundColor DarkGray

# ---- 1. activation key -----------------------------------------------
# Checked here as well as in the running app: failing before anything is
# downloaded or installed is a much better experience than failing after.
Step 1 'Activation key / מפתח הפעלה'

function Get-KeyHash($key) {
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($key.Trim().ToUpperInvariant())
    return (-join ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }))
}

$key = Read-Host '    Enter your key (MHW-XXXX-XXXX-XXXX)'
if (-not $key) { Line '    No key entered. Stopping.' 'Red'; return }

try {
    $allow = Invoke-RestMethod -Uri $ALLOW_URL -TimeoutSec 30
} catch {
    Line "    Could not reach the key list: $($_.Exception.Message)" 'Red'
    Line '    Check the internet connection and try again.' 'Yellow'
    return
}

$hash  = Get-KeyHash $key
$entry = $allow.keys.PSObject.Properties | Where-Object { $_.Name -eq $hash }

if (-not $entry) {
    Line '    That key is not recognised.' 'Red'
    Line '    Ask Matan for a key, or check for a typo.' 'Yellow'
    return
}
$info = $entry.Value
if ($info.expires -and ([datetime]$info.expires) -lt (Get-Date)) {
    Line "    That key expired on $($info.expires)." 'Red'
    return
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
    winget install --id GitHub.cli --exact --silent --accept-package-agreements --accept-source-agreements | Out-Null
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

& $gh auth status 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Line '    A browser window will open to sign in to GitHub.' 'Gray'
    & $gh auth login --hostname github.com --git-protocol https --web
    if ($LASTEXITCODE -ne 0) { Line '    Sign-in did not complete. Stopping.' 'Red'; return }
}
$who = (& $gh api user --jq '.login' 2>$null)
Line "    OK - signed in as $who" 'Green'

# ---- 3. fetch ---------------------------------------------------------
Step 3 'Downloading MediaHub'

if (Test-Path (Join-Path $INSTALL_TO '.git')) {
    Line "    Already present at $INSTALL_TO - updating instead." 'Gray'
    Push-Location $INSTALL_TO
    & $gh repo sync 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { & git pull --ff-only 2>&1 | Out-Null }
    Pop-Location
} else {
    New-Item -ItemType Directory -Force -Path (Split-Path $INSTALL_TO) | Out-Null
    & $gh repo clone "$OWNER/$REPO" $INSTALL_TO 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Line '    Could not download the repository.' 'Red'
        Line "    The account $who has a valid key but no access to the code." 'Yellow'
        Line '    Ask Matan to add you as a collaborator, then run this again.' 'Yellow'
        return
    }
}
Line "    OK - $INSTALL_TO" 'Green'

# ---- 4. hand off ------------------------------------------------------
Step 4 'Starting the installer'

# The key is passed through so the installer does not ask a second time, and
# so it can record which key this machine was activated with.
$installer = Join-Path $INSTALL_TO 'install.ps1'
if (-not (Test-Path $installer)) { Line "    Missing: $installer" 'Red'; return }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Key $key
