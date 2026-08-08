# GTA FPV Drone installer (Windows). Copies (or links) drone.lua + drone/
# into a GTA San Andreas install, checks for the MoonLoader libraries this
# script needs, and sets up the controller bridge daemon.

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir

function Say($msg)  { Write-Host $msg }
function Ok($msg)   { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Err($msg)  { Write-Host $msg -ForegroundColor Red }

Say "=== GTA FPV Drone installer ==="
Say "This copies drone.lua + drone/ from:"
Say "  $RepoDir"
Say "into your GTA San Andreas install, and checks required MoonLoader libraries."
Say ""

# --- 1. GTA SA path -------------------------------------------------------
$GtaPath = Read-Host "Path to your GTA San Andreas folder"
# Explorer's "Copy as path" wraps the path in quotes -- strip them.
$GtaPath = $GtaPath.Trim().Trim('"').TrimEnd('\')

if (-not (Test-Path $GtaPath -PathType Container)) {
    Err "That folder doesn't exist: $GtaPath"
    exit 1
}
if (-not (Test-Path (Join-Path $GtaPath "gta_sa.exe"))) {
    Warn "Warning: no gta_sa.exe found there -- are you sure this is the right folder?"
}
if (-not (Test-Path (Join-Path $GtaPath "moonloader") -PathType Container)) {
    Err "No moonloader\ folder found in $GtaPath -- install MoonLoader first (https://blast.hk/moonloader/), then re-run this installer."
    Read-Host "Press Enter to exit"
    exit 1
}

# --- 2. Dependency check, all at once --------------------------------------
Say ""
Say "--- Checking dependencies ---"

$Missing = @()
function Check($Label, $Path, $Link) {
    if (Test-Path $Path) {
        Ok "  [OK]      $Label"
    } else {
        Err "  [MISSING] $Label"
        $script:Missing += "$Label -- $Link"
    }
}

Check "MoonLoader (moonloader.asi)"   (Join-Path $GtaPath "moonloader.asi")                  "https://blast.hk/moonloader/"
Check "mimgui"                        (Join-Path $GtaPath "moonloader\lib\mimgui")           "https://github.com/THE-FYP/mimgui"
Check "SAMemory"                      (Join-Path $GtaPath "moonloader\lib\SAMemory")         "search blast.hk's MoonLoader library section for 'SAMemory'"
Check "luasocket"                     (Join-Path $GtaPath "moonloader\lib\luasocket")         "https://github.com/lunarmodules/luasocket (or a MoonLoader 'extra libraries' pack on blast.hk)"
Check "bass.lua (BASS FFI wrapper)"   (Join-Path $GtaPath "moonloader\lib\bass.lua")          "search blast.hk's MoonLoader library section for a 'bass.lua' wrapper"
Check "bass.dll (BASS audio library)" (Join-Path $GtaPath "bass.dll")                         "https://www.un4seen.com/ (free for non-commercial use)"

Say ""
if ($Missing.Count -eq 0) {
    Ok "All dependencies found."
} else {
    Warn "Missing $($Missing.Count) dependency(ies) -- the drone script needs ALL of these to work:"
    foreach ($m in $Missing) { Say "  - $m" }
    Say "Install them, then re-run this installer (or just copy the files below now and add libraries later)."
}

# --- 3. Copy or link --------------------------------------------------------
Say ""
Say "--- Install mode ---"
Say "  copy - plain copy, works from a downloaded zip or a git clone (recommended)"
Say "  link - drone\ is linked back to this folder (git pull updates your install); only useful if you cloned this with git, and needs no admin rights (uses a directory junction)"
$Mode = Read-Host "Copy or link? [copy]"
if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = "copy" }

$DestLua = Join-Path $GtaPath "moonloader\drone.lua"
$DestDir = Join-Path $GtaPath "moonloader\drone"

if (Test-Path $DestDir) {
    $Existing = Get-Item $DestDir -Force
    if ($Existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        # A junction from a previous 'link' install: delete only the link
        # itself -- Remove-Item -Recurse would follow it and wipe the
        # repo's drone/ folder.
        $Existing.Delete()
    } else {
        Remove-Item $DestDir -Recurse -Force
    }
}
Copy-Item (Join-Path $RepoDir "drone.lua") $DestLua -Force

if ($Mode -eq "link") {
    try {
        New-Item -ItemType Junction -Path $DestDir -Target (Join-Path $RepoDir "drone") -ErrorAction Stop | Out-Null
        Ok "Linked $DestDir -> $RepoDir\drone (junction, no admin rights needed)"
    } catch {
        Warn "Could not create a junction ($($_.Exception.Message)) -- junctions only work within the same drive. Falling back to a plain copy."
        Copy-Item (Join-Path $RepoDir "drone") $DestDir -Recurse -Force
    }
} else {
    Copy-Item (Join-Path $RepoDir "drone") $DestDir -Recurse -Force
    Ok "Copied drone\ into $DestDir"
}
Ok "Copied drone.lua into $DestLua"

# --- 4. uv (runs the controller bridge, auto-installs its one dependency) --
Say ""
Say "--- Controller bridge (uv) ---"
Say "The bridge (controllerd.py) declares its own dependency (pysdl2) inline"
Say "and runs via 'uv run', which installs it automatically on first run."

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Warn "uv not found."
    $InstallUv = Read-Host "Install it now? [Y/n]"
    if ($InstallUv -ne "n" -and $InstallUv -ne "N") {
        Invoke-Expression (Invoke-RestMethod "https://astral.sh/uv/install.ps1")
        # The official installer updates the user PATH registry value, which
        # this already-running session won't see until restart -- resolve it
        # directly for the rest of this script instead.
        if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
            $UvBin = Join-Path $env:USERPROFILE ".local\bin"
            if (Test-Path (Join-Path $UvBin "uv.exe")) { $env:Path = "$UvBin;$env:Path" }
        }
    }
}

if (Get-Command uv -ErrorAction SilentlyContinue) {
    Ok "Found uv: $(uv --version 2>&1)"
} else {
    Err "uv still not found -- install it manually: https://docs.astral.sh/uv/getting-started/installation/"
    Err "(or install Python 3 + 'pip install pysdl2' yourself and run controllerd.py with plain python instead)"
}

$BridgePy = Join-Path $DestDir "bridge\controllerd.py"
$RunCmd = "uv run `"$BridgePy`""

# --- 5. Auto-start or manual -------------------------------------------------
Say ""
Say "--- Controller bridge startup ---"
Say "The bridge must be running whenever you want to fly the drone. The exact command to run it manually:"
Say ""
Say "  $RunCmd"
Say ""
$AutoStart = Read-Host "Set it up to start automatically when you log in? [y/N]"
if ($AutoStart -eq "y" -or $AutoStart -eq "Y") {
    $StartupDir = [Environment]::GetFolderPath("Startup")
    $BatPath = Join-Path $StartupDir "gta-fpv-drone-bridge.bat"
    # OEM encoding: cmd.exe reads .bat files in the OEM codepage, so paths
    # with non-ASCII characters (e.g. a Cyrillic user name) survive intact.
    "@echo off`r`nstart `"`" uv run `"$BridgePy`"" | Out-File -FilePath $BatPath -Encoding oem
    Ok "Created $BatPath -- the bridge will start next time you log in."
    Say "To start it right now too:"
    Say "  $RunCmd"
} else {
    Say "Skipped -- run the command above yourself whenever you want to fly."
}

# --- 6. Summary ---------------------------------------------------------------
Say ""
Say "=== Done ==="
Say "Installed to: $DestLua and $DestDir"
Say "Manual bridge command: $RunCmd"
Say "In-game: type DRONE to spawn (throttle near zero to arm), CFGD for settings. See README.md for default keybinds."
Read-Host "Press Enter to exit"
