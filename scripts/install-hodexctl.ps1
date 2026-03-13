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

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
$controllerPath = Join-Path $tempRoot "hodexctl.ps1"

try {
  $ProgressPreference = "SilentlyContinue"
  New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
  Write-Host "==> Download hodexctl manager script"
  Invoke-WebRequest -Uri $controllerUrl -OutFile $controllerPath

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

  $runner = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
  Write-Host "==> Start hodexctl initial install"
  & $runner @argumentList
  if ($LASTEXITCODE -ne 0) {
    throw "hodexctl manager-install failed, exit code: $LASTEXITCODE"
  }

  Write-Host "==> Install complete"
  if ($env:HODEXCTL_NO_PATH_UPDATE -eq "1") {
    Write-Host "==> PATH update skipped; you can run: $resolvedWrapperCmd status"
  } else {
    if (-not (Get-Command hodexctl -ErrorAction SilentlyContinue)) {
      Refresh-SessionPathFromRegistry
    }
    if (Get-Command hodexctl -ErrorAction SilentlyContinue) {
      Write-Host "==> Current session PATH refreshed; you can run: hodexctl status"
    } else {
      $env:Path = "$resolvedCommandDir;$env:Path"
      Write-Host "==> Command dir added to current session PATH; you can run: hodexctl status"
    }
  }
} finally {
  $ProgressPreference = $originalProgressPreference
  if (Test-Path $tempRoot) {
    Remove-Item -Recurse -Force $tempRoot
  }
}
