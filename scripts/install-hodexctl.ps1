$ErrorActionPreference = "Stop"
$originalProgressPreference = $ProgressPreference

$repo = if ($env:HODEXCTL_REPO) { $env:HODEXCTL_REPO } elseif ($env:CODEX_REPO) { $env:CODEX_REPO } else { "wintsa123/codex-cn" }
$controllerUrlBase = if ($env:HODEX_CONTROLLER_URL_BASE) { $env:HODEX_CONTROLLER_URL_BASE.TrimEnd('/') } else { "https://raw.githubusercontent.com" }
$controllerRef = if ($env:HODEX_CONTROLLER_REF) { $env:HODEX_CONTROLLER_REF } else { "main" }
$stateDir = if ($env:HODEX_STATE_DIR) { $env:HODEX_STATE_DIR } else { $null }
$commandDir = if ($env:HODEX_COMMAND_DIR) { $env:HODEX_COMMAND_DIR } elseif ($env:INSTALL_DIR) { $env:INSTALL_DIR } else { $null }
$controllerUrl = "$controllerUrlBase/$repo/$controllerRef/scripts/hodexctl/hodexctl.ps1"

$resolvedStateDir = if ($stateDir) {
  $stateDir
} elseif ($env:LOCALAPPDATA) {
  Join-Path $env:LOCALAPPDATA "hodex"
} else {
  Join-Path $HOME "AppData\\Local\\hodex"
}
$resolvedCommandDir = if ($commandDir) { $commandDir } else { Join-Path $resolvedStateDir "commands" }
$resolvedWrapperCmd = Join-Path $resolvedCommandDir "hodexctl.cmd"

function Fail-Installer {
  param([string]$Message)
  [Console]::Error.WriteLine($Message)
  exit 1
}

function Refresh-SessionPathFromRegistry {
  $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
  $combined = ""

  if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
    $combined = $machinePath
  }
  if (-not [string]::IsNullOrWhiteSpace($userPath)) {
    if ([string]::IsNullOrWhiteSpace($combined)) {
      $combined = $userPath
    } else {
      $combined = "$combined;$userPath"
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($combined)) {
    $env:Path = $combined
  }
}

function Invoke-ControllerDownloadWithRetry {
  param(
    [string]$Uri,
    [string]$OutFile
  )

  $delayMilliseconds = 1000
  $lastMessage = ""
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    try {
      Invoke-WebRequest -Uri $Uri -OutFile $OutFile
      return
    } catch {
      $lastMessage = $_.Exception.Message
      if ($attempt -eq 3) {
        throw "Failed to download hodexctl manager script from ${Uri}: $lastMessage"
      }
      Start-Sleep -Milliseconds $delayMilliseconds
      $delayMilliseconds *= 2
    }
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$controllerPath = Join-Path $tempRoot "hodexctl.ps1"

try {
  if ($env:OS -ne "Windows_NT") {
    Fail-Installer "This installer supports Windows PowerShell only; use install-hodexctl.sh on macOS/Linux/WSL."
  }
  $ProgressPreference = "SilentlyContinue"
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  Write-Host "==> Download hodexctl manager script"
  Invoke-ControllerDownloadWithRetry -Uri $controllerUrl -OutFile $controllerPath

  $argumentList = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $controllerPath,
    "manager-install",
    "-Yes",
    "-Repo", $repo
  )

  if ($stateDir) {
    $argumentList += @("-StateDir", $stateDir)
  }

  if ($commandDir) {
    $argumentList += @("-CommandDir", $commandDir)
  }

  if ($env:HODEXCTL_NO_PATH_UPDATE -eq "1") {
    $argumentList += "-NoPathUpdate"
  }

  if ($env:GITHUB_TOKEN) {
    $argumentList += @("-GitHubToken", $env:GITHUB_TOKEN)
  }

  $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
  if ($pwsh -and -not [string]::IsNullOrWhiteSpace($pwsh.Source)) {
    $runner = $pwsh.Source
  } else {
    $powershellFallback = Join-Path $PSHOME "powershell.exe"
    if (Test-Path -LiteralPath $powershellFallback) {
      $runner = $powershellFallback
    } else {
      $runner = "powershell"
    }
  }
  Write-Host "==> Start hodexctl initial install"
  & $runner @argumentList
  if ($LASTEXITCODE -ne 0) {
    Fail-Installer "hodexctl manager-install failed, exit code: $LASTEXITCODE"
  }

  Write-Host "==> Install complete"
  if ($env:HODEXCTL_NO_PATH_UPDATE -eq "1") {
    Write-Host "==> PATH update skipped; you can run: $resolvedWrapperCmd status"
  } else {
    $sessionPathAdjusted = $false

    if (-not (Get-Command hodexctl -ErrorAction SilentlyContinue)) {
      Refresh-SessionPathFromRegistry
    }

    $hodexctlCommand = Get-Command hodexctl -ErrorAction SilentlyContinue
    $hodexctlCommandDir = if ($hodexctlCommand -and $hodexctlCommand.Source) { Split-Path -Parent $hodexctlCommand.Source } else { "" }
    $resolvedCommandDirNormalized = $resolvedCommandDir.TrimEnd("\\")
    $hodexctlIsExpected = -not [string]::IsNullOrWhiteSpace($hodexctlCommandDir) -and $hodexctlCommandDir.TrimEnd("\\") -ieq $resolvedCommandDirNormalized

    if (-not $hodexctlIsExpected) {
      $pathParts = @()
      foreach ($part in ($env:Path -split ";")) {
        if ([string]::IsNullOrWhiteSpace($part)) {
          continue
        }
        if ($part.TrimEnd("\\") -ieq $resolvedCommandDirNormalized) {
          continue
        }
        $pathParts += $part
      }
      $env:Path = ($resolvedCommandDirNormalized, $pathParts) -join ";"
      $sessionPathAdjusted = $true

      $hodexctlCommand = Get-Command hodexctl -ErrorAction SilentlyContinue
      $hodexctlCommandDir = if ($hodexctlCommand -and $hodexctlCommand.Source) { Split-Path -Parent $hodexctlCommand.Source } else { "" }
      $hodexctlIsExpected = -not [string]::IsNullOrWhiteSpace($hodexctlCommandDir) -and $hodexctlCommandDir.TrimEnd("\\") -ieq $resolvedCommandDirNormalized
    }

    if ($hodexctlIsExpected) {
      if ($sessionPathAdjusted) {
        Write-Host "==> Command dir added to current session PATH; you can run: hodexctl status"
      } else {
        Write-Host "==> Current session PATH refreshed; you can run: hodexctl status"
      }
    } else {
      Write-Host "==> Command dir added to current session PATH; you can run: $resolvedWrapperCmd status"
    }
  }
} catch {
  $message = $_.Exception.Message
  if ([string]::IsNullOrWhiteSpace($message)) {
    $message = ($_ | Out-String).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($message)) {
    $message = "Failed to install hodexctl."
  }
  Fail-Installer $message
} finally {
  $ProgressPreference = $originalProgressPreference
  if (Test-Path $tempRoot) {
    Remove-Item -Recurse -Force $tempRoot
  }
}
