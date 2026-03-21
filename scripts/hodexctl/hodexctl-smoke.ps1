param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$controllerPath = Join-Path $scriptDir "hodexctl.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("hodexctl-smoke-" + [System.Guid]::NewGuid().ToString("N"))

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected
    )

    if ($Text -notlike "*$Expected*") {
        throw "Expected content not found: $Expected"
    }
}

function Get-Runner {
    if (Get-Command pwsh -ErrorAction SilentlyContinue) {
        return "pwsh"
    }

    return "powershell"
}

function Invoke-RunnerCapture {
    param(
        [string]$Runner,
        [string[]]$ArgumentList
    )

    $stdoutPath = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N") + ".stdout.txt")
    $stderrPath = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N") + ".stderr.txt")
    try {
        $process = Start-Process -FilePath $Runner -ArgumentList $ArgumentList -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut = if (Test-Path $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw } else { "" }
            StdErr = if (Test-Path $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw } else { "" }
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function New-FakeSummaryAgent {
    param(
        [string]$BinDir,
        [string]$Name,
        [bool]$SupportsExec,
        [string]$ResultText,
        [string]$ArgsFile,
        [string]$PromptFile = ""
    )

    if ($env:OS -eq "Windows_NT") {
        $path = Join-Path $BinDir ($Name + ".cmd")
        $content = @"
@echo off
if "%1"=="exec" if "%2"=="--help" (
  $(if ($SupportsExec) { "exit /b 0" } else { "exit /b 1" })
)
echo %* > "$ArgsFile"
$(if ([string]::IsNullOrWhiteSpace($PromptFile)) { "more > NUL" } else { "more > ""$PromptFile""" })
echo {\"type\":\"item.completed\",\"item\":{\"id\":\"item_0\",\"type\":\"agent_message\",\"text\":\"$ResultText\"}}
"@
        Set-Content -LiteralPath $path -Value $content -Encoding ASCII
        return
    }

    $path = Join-Path $BinDir $Name
    $content = @"
#!/usr/bin/env bash
set -euo pipefail
if [[ "`${1:-}" == "exec" && "`${2:-}" == "--help" ]]; then
  $(if ($SupportsExec) { "exit 0" } else { "exit 1" })
fi
printf '%s\n' "`$*" >"$ArgsFile"
$(if ([string]::IsNullOrWhiteSpace($PromptFile)) { "cat >/dev/null" } else { "cat >""$PromptFile""" })
printf '%s\n' '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"$ResultText"}}'
"@
        Set-Content -LiteralPath $path -Value $content -Encoding UTF8
        & chmod +x $path
}

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    $smokeStateDir = Join-Path $tempRoot "state"
    $smokeCommandDir = Join-Path $tempRoot "commands"
    $releaseStateDir = Join-Path $tempRoot "release-state"
    $releaseCommandDir = Join-Path $tempRoot "release-commands"
    $sourceRepoDir = Join-Path $tempRoot "source-repo"
    $smokeSourceCheckoutDir = Join-Path $tempRoot "source-checkout"
    $summaryBin = Join-Path $tempRoot "summary-bin"
    $summaryArgs = Join-Path $tempRoot "summary-args.txt"
    $summaryPrompt = Join-Path $tempRoot "summary-prompt.txt"
    $summaryFallbackBin = Join-Path $tempRoot "summary-fallback-bin"
    $summaryFallbackArgs = Join-Path $tempRoot "summary-fallback-args.txt"

    Write-Host "==> Check PowerShell syntax"
    [void][System.Management.Automation.Language.Parser]::ParseFile($controllerPath, [ref]$null, [ref]$null)

    Write-Host "==> Check graceful error output"
    New-Item -ItemType Directory -Path $smokeStateDir -Force | Out-Null
    New-Item -ItemType Directory -Path $smokeCommandDir -Force | Out-Null
    $runner = Get-Runner
    $gracefulErrorResult = Invoke-RunnerCapture -Runner $runner -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $controllerPath,
        "downgrade",
        "-StateDir", $smokeStateDir,
        "-CommandDir", $smokeCommandDir
    )
    if ($gracefulErrorResult.ExitCode -ne 1) { throw "Expected exit code 1; got: $($gracefulErrorResult.ExitCode)" }
    if (-not [string]::IsNullOrWhiteSpace($gracefulErrorResult.StdOut)) {
        throw "Expected empty stdout for graceful error path; got:`n$($gracefulErrorResult.StdOut)"
    }
    Assert-Contains -Text $gracefulErrorResult.StdErr -Expected "downgrade requires an explicit version"
    if ($gracefulErrorResult.StdErr -like "*CategoryInfo*") { throw "Unexpected PowerShell CategoryInfo noise in error output" }
    if ($gracefulErrorResult.StdErr -like "*FullyQualifiedErrorId*") { throw "Unexpected PowerShell FullyQualifiedErrorId noise in error output" }
    if ($gracefulErrorResult.StdErr -like "*At line:*") { throw "Unexpected PowerShell location noise in error output" }

    Write-Host "==> Check help output"
    $helpOutput = (& $runner -NoProfile -File $controllerPath -Help 2>&1 | Out-String)
    Assert-Contains -Text $helpOutput -Expected "Usage:"
    Assert-Contains -Text $helpOutput -Expected "hodexctl list"
    Assert-Contains -Text $helpOutput -Expected ".\hodexctl.ps1 install"
    Assert-Contains -Text $helpOutput -Expected "source <action>"

    Write-Host "==> Check downgrade accepts explicit version argument"
    $downgradeHelpOutput = (& $runner -NoProfile -File $controllerPath downgrade 1.0.0 -Help 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "Expected exit code 0; got: $LASTEXITCODE`n$downgradeHelpOutput" }
    Assert-Contains -Text $downgradeHelpOutput -Expected "Usage:"

    Write-Host "==> Check source mode help output"
    $sourceHelpOutput = (& $runner -NoProfile -File $controllerPath source help 2>&1 | Out-String)
    Assert-Contains -Text $sourceHelpOutput -Expected "Source mode usage:"
    Assert-Contains -Text $sourceHelpOutput -Expected "install                Download source and prepare toolchain (does not take over hodex)"
    Assert-Contains -Text $sourceHelpOutput -Expected "Source profile name (workspace id), default codex-source"

    Write-Host "==> Check source/list help semantics"
    $sourceInstallHelpOutput = (& $runner -NoProfile -File $controllerPath source install -Help 2>&1 | Out-String)
    $listHelpOutput = (& $runner -NoProfile -File $controllerPath list -Help 2>&1 | Out-String)
    Assert-Contains -Text $sourceInstallHelpOutput -Expected "Source mode usage:"
    Assert-Contains -Text $listHelpOutput -Expected "Release list usage:"
    Assert-Contains -Text $listHelpOutput -Expected "Changelog view actions:"

    Write-Host "==> Check release changelog summary prefers hodex"
    New-Item -ItemType Directory -Path $summaryBin -Force | Out-Null
    New-FakeSummaryAgent -BinDir $summaryBin -Name "hodex" -SupportsExec $true -ResultText "This is the hodex summary result" -ArgsFile $summaryArgs -PromptFile $summaryPrompt
    New-FakeSummaryAgent -BinDir $summaryBin -Name "codex" -SupportsExec $true -ResultText "codex should not be called" -ArgsFile (Join-Path $tempRoot "unexpected-codex.txt")
    $originalPath = $env:PATH
    try {
        $env:PATH = $summaryBin + [System.IO.Path]::PathSeparator + $env:PATH
        $env:HODEXCTL_SKIP_MAIN = "1"
        . $controllerPath
        Remove-Item Env:\HODEXCTL_SKIP_MAIN -ErrorAction SilentlyContinue
        $releaseInfo = [pscustomobject]@{
            version = "1.2.3"
            release_name = "1.2.3"
            release_tag = "v1.2.3"
            published_at = "2026-03-09T00:00:00Z"
            html_url = "https://example.invalid/releases/v1.2.3"
            asset = [pscustomobject]@{ name = "codex-x86_64-apple-darwin" }
            release = [pscustomobject]@{ body = "- add feature A`n- fix bug B" }
        }
        $summaryResult = Invoke-ReleaseSummary -ReleaseInfo $releaseInfo
        if (-not $summaryResult) { throw "Invoke-ReleaseSummary did not call hodex successfully" }
        Assert-Contains -Text (Get-Content -LiteralPath $summaryArgs -Raw) -Expected "exec --skip-git-repo-check --color never --json -"
        Assert-Contains -Text (Get-Content -LiteralPath $summaryPrompt -Raw) -Expected "Version: 1.2.3"
        Assert-Contains -Text (Get-Content -LiteralPath $summaryPrompt -Raw) -Expected "Full changelog:"
        Assert-Contains -Text (Get-Content -LiteralPath $summaryPrompt -Raw) -Expected "New features"
        Assert-Contains -Text (Get-Content -LiteralPath $summaryPrompt -Raw) -Expected "Improvements"
        Assert-Contains -Text (Get-Content -LiteralPath $summaryPrompt -Raw) -Expected "Fixes"
        Assert-Contains -Text (Get-Content -LiteralPath $summaryPrompt -Raw) -Expected "- add feature A"
    } finally {
        $env:PATH = $originalPath
        Remove-Item Env:\HODEXCTL_SKIP_MAIN -ErrorAction SilentlyContinue
    }

    Write-Host "==> Check release changelog summary falls back to codex"
    New-Item -ItemType Directory -Path $summaryFallbackBin -Force | Out-Null
    New-FakeSummaryAgent -BinDir $summaryFallbackBin -Name "hodex" -SupportsExec $false -ResultText "hodex should not be called" -ArgsFile (Join-Path $tempRoot "unsupported-hodex.txt")
    New-FakeSummaryAgent -BinDir $summaryFallbackBin -Name "codex" -SupportsExec $true -ResultText "This is the codex fallback summary" -ArgsFile $summaryFallbackArgs
    $originalPath = $env:PATH
    try {
        $env:PATH = $summaryFallbackBin + [System.IO.Path]::PathSeparator + $env:PATH
        $env:HODEXCTL_SKIP_MAIN = "1"
        . $controllerPath
        Remove-Item Env:\HODEXCTL_SKIP_MAIN -ErrorAction SilentlyContinue
        $releaseInfo = [pscustomobject]@{
            version = "2.0.0"
            release_name = "2.0.0"
            release_tag = "v2.0.0"
            published_at = "2026-03-09T00:00:00Z"
            html_url = "https://example.invalid/releases/v2.0.0"
            asset = [pscustomobject]@{ name = "codex-x86_64-apple-darwin" }
            release = [pscustomobject]@{ body = "fallback smoke" }
        }
        $summaryResult = Invoke-ReleaseSummary -ReleaseInfo $releaseInfo
        if (-not $summaryResult) { throw "Invoke-ReleaseSummary did not fall back to codex" }
        Assert-Contains -Text (Get-Content -LiteralPath $summaryFallbackArgs -Raw) -Expected "exec --skip-git-repo-check --color never --json -"
    } finally {
        $env:PATH = $originalPath
        Remove-Item Env:\HODEXCTL_SKIP_MAIN -ErrorAction SilentlyContinue
    }

    Write-Host "==> Check source mode refuses to take over hodex"
    $activateResult = Invoke-RunnerCapture -Runner $runner -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $controllerPath,
        "source",
        "install",
        "-Activate"
    )
    if ($activateResult.ExitCode -eq 0) {
        throw "Source mode should not accept -Activate"
    }
    if (-not [string]::IsNullOrWhiteSpace($activateResult.StdOut)) {
        throw "Expected empty stdout for -Activate refusal; got:`n$($activateResult.StdOut)"
    }
    Assert-Contains -Text $activateResult.StdErr -Expected "Source mode does not take over hodex"

    Write-Host "==> Check manager-install does not fake hodex release"
    $env:HODEXCTL_SKIP_MAIN = "1"
    . $controllerPath
    Remove-Item Env:\HODEXCTL_SKIP_MAIN -ErrorAction SilentlyContinue
    $script:StateRoot = Join-Path $tempRoot "manager-only-state"
    $script:CurrentCommandDir = Join-Path $script:StateRoot "commands"
    $script:PathUpdateMode = "disabled"
    $script:PathProfile = ""
    $script:PlatformLabel = "Windows"
    Write-State `
        -InstalledVersion "" `
        -ReleaseTag "" `
        -ReleaseName "" `
        -AssetName "" `
        -BinaryPath "" `
        -ControllerPath (Join-Path $script:StateRoot "libexec\hodexctl.ps1") `
        -CurrentCommandDir $script:CurrentCommandDir `
        -WrappersCreated @(
            (Join-Path $script:CurrentCommandDir "hodexctl.cmd"),
            (Join-Path $script:CurrentCommandDir "hodexctl.ps1")
        ) `
        -CurrentPathUpdateMode "disabled" `
        -CurrentPathProfile "" `
        -CurrentNodeSetupChoice "" `
        -InstalledAt "2026-03-09T00:00:00Z"
    $managerOnlyState = Get-Content -LiteralPath (Join-Path $script:StateRoot "state.json") -Raw
    if ($managerOnlyState -like '*"hodex": "release"*') {
        throw "manager-install should not fake hodex release alias"
    }

    Write-Host "==> Check manager-install wrappers preserve custom state dir"
    $customStateDir = Join-Path $tempRoot "manager-wrapper-state"
    $customCommandDir = Join-Path $customStateDir "commands"
    $customControllerPath = Join-Path $customStateDir "libexec\hodexctl.ps1"
    New-Item -ItemType Directory -Path $customCommandDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $customControllerPath) -Force | Out-Null
    Copy-Item -LiteralPath $controllerPath -Destination $customControllerPath -Force
    $script:StateRoot = $customStateDir
    $script:State = [pscustomobject]@{
        schema_version = 2
        repo = 'stellarlinkco/codex'
        installed_version = ''
        release_tag = ''
        release_name = ''
        asset_name = ''
        binary_path = ''
        controller_path = $customControllerPath
        command_dir = $customCommandDir
        wrappers_created = @()
        path_update_mode = 'disabled'
        path_profile = ''
        node_setup_choice = ''
        installed_at = '2026-03-09T00:00:00Z'
        source_profiles = [ordered]@{}
        active_runtime_aliases = [ordered]@{}
    }
    Sync-RuntimeWrappersFromState -CommandDir $customCommandDir -ControllerPath $customControllerPath
    $wrapperPath = Join-Path $customCommandDir 'hodexctl.ps1'
    if (!(Test-Path $wrapperPath)) { throw 'manager-install wrapper missing' }
    $wrapperContent = Get-Content -LiteralPath $wrapperPath -Raw
    Assert-Contains -Text $wrapperContent -Expected ('$env:HODEX_STATE_DIR = "' + $customStateDir + '"')
    Assert-Contains -Text $wrapperContent -Expected ('$forwardedArgs = @($args)')
    Assert-Contains -Text $wrapperContent -Expected ('@("-StateDir", "' + $customStateDir + '") + $forwardedArgs')

    if ($env:OS -ne "Windows_NT") {
        Write-Host "==> Check install-hodexctl.ps1 fails cleanly on non-Windows"
        $installScriptPath = Join-Path (Split-Path -Parent $scriptDir) 'install-hodexctl.ps1'
        $nonWindowsInstallResult = Invoke-RunnerCapture -Runner $runner -ArgumentList @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $installScriptPath
        )
        if ($nonWindowsInstallResult.ExitCode -ne 1) { throw "Expected exit code 1 on non-Windows installer run; got: $($nonWindowsInstallResult.ExitCode)" }
        if (-not [string]::IsNullOrWhiteSpace($nonWindowsInstallResult.StdOut)) {
            throw "Expected empty stdout for non-Windows installer failure; got:`n$($nonWindowsInstallResult.StdOut)"
        }
        Assert-Contains -Text $nonWindowsInstallResult.StdErr -Expected "This installer supports Windows PowerShell only; use install-hodexctl.sh on macOS/Linux/WSL."
        if ($nonWindowsInstallResult.StdErr -like "*CategoryInfo*") { throw "Unexpected PowerShell CategoryInfo noise in non-Windows installer output" }
        if ($nonWindowsInstallResult.StdErr -like "*FullyQualifiedErrorId*") { throw "Unexpected PowerShell FullyQualifiedErrorId noise in non-Windows installer output" }
        if ($nonWindowsInstallResult.StdErr -like "*Line |*") { throw "Unexpected PowerShell location noise in non-Windows installer output" }
        if ($nonWindowsInstallResult.StdErr -like "*At line:*") { throw "Unexpected PowerShell location noise in non-Windows installer output" }
    }

    if ($env:OS -eq "Windows_NT") {
        $statusViaWrapper = (& $runner -NoProfile -File $wrapperPath status 2>&1 | Out-String)
        Assert-Contains -Text $statusViaWrapper -Expected ("State dir: " + $customStateDir)
        Assert-Contains -Text $statusViaWrapper -Expected "Release install status: not installed"
        Write-Host "==> Check not-installed status output"
        $statusOutput = (& $runner -NoProfile -File $controllerPath status -StateDir $smokeStateDir 2>&1 | Out-String)
	        Assert-Contains -Text $statusOutput -Expected "Release install status: not installed"
	        Assert-Contains -Text $statusOutput -Expected ("State dir: " + $smokeStateDir)

	        Write-Host "==> Check install-hodexctl.ps1 refreshes current session PATH"
	        $installerRepo = "smoke-repo"
	        $installerAssetsDir = Join-Path $tempRoot 'installer-assets'
	        $installerControllerDir = Join-Path $installerAssetsDir (Join-Path $installerRepo 'main\scripts\hodexctl')
	        $installerControllerScript = Join-Path $installerControllerDir 'hodexctl.ps1'
	        New-Item -ItemType Directory -Path $installerControllerDir -Force | Out-Null
	        Copy-Item -LiteralPath $controllerPath -Destination $installerControllerScript -Force

	        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
	        $listener.Start()
	        $installerPort = $listener.LocalEndpoint.Port
	        $listener.Stop()
	        $installerServer = Start-Process -FilePath python -ArgumentList @("-m", "http.server", "$installerPort", "--bind", "127.0.0.1", "--directory", "$installerAssetsDir") -PassThru -NoNewWindow
	        try {
	            for ($i = 0; $i -lt 50; $i++) {
	                try {
	                    Invoke-WebRequest -Uri "http://127.0.0.1:$installerPort/" -UseBasicParsing | Out-Null
	                    break
	                } catch {
	                    Start-Sleep -Milliseconds 100
	                }
	            }

	            $installStateDir = Join-Path $tempRoot 'installer-state'
	            $installCommandDir = Join-Path $tempRoot 'installer-command'
	            New-Item -ItemType Directory -Path $installStateDir -Force | Out-Null
	            New-Item -ItemType Directory -Path $installCommandDir -Force | Out-Null

		            $installScriptPath = Join-Path (Split-Path -Parent $scriptDir) 'install-hodexctl.ps1'
		            $originalUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
		            $originalProcessPath = $env:Path
		            $originalProgressPreference = $ProgressPreference
		            try {
		                $ProgressPreference = "Continue"
		                $env:HODEXCTL_REPO = $installerRepo
		                $env:HODEX_CONTROLLER_URL_BASE = "http://127.0.0.1:$installerPort"
		                $env:HODEX_STATE_DIR = $installStateDir
		                $env:HODEX_COMMAND_DIR = $installCommandDir
		                Remove-Item Env:\HODEXCTL_NO_PATH_UPDATE -ErrorAction SilentlyContinue

		                $installerOutput = (& $installScriptPath *>&1 | Out-String)
		                Assert-Contains -Text $installerOutput -Expected "current session PATH"
		                $hodexctlSource = (Get-Command hodexctl -ErrorAction Stop).Source
		                Assert-Contains -Text $hodexctlSource -Expected $installCommandDir
		                $statusAfterInstall = (& hodexctl status 2>&1 | Out-String)
		                Assert-Contains -Text $statusAfterInstall -Expected ("State dir: " + $installStateDir)
		                if ($ProgressPreference -ne "Continue") { throw "install-hodexctl.ps1 should not modify ProgressPreference" }
		            } finally {
		                $ProgressPreference = $originalProgressPreference
		                [Environment]::SetEnvironmentVariable("Path", $originalUserPath, "User")
		                $env:Path = $originalProcessPath
		                Remove-Item Env:\HODEXCTL_REPO -ErrorAction SilentlyContinue
		                Remove-Item Env:\HODEX_CONTROLLER_URL_BASE -ErrorAction SilentlyContinue
		                Remove-Item Env:\HODEX_STATE_DIR -ErrorAction SilentlyContinue
	                Remove-Item Env:\HODEX_COMMAND_DIR -ErrorAction SilentlyContinue
	            }
	        } finally {
	            try { if ($installerServer -and -not $installerServer.HasExited) { $installerServer.Kill() } } catch {}
	        }

	        Write-Host "==> Check release-only install and uninstall cleanup"
	        $assetsDir = Join-Path $tempRoot 'release-assets'
	        $releaseDir = Join-Path $assetsDir 'latest\download'
	        $brokenReleaseDir = Join-Path $tempRoot 'broken-release-assets\latest\download'
	        New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null
        New-Item -ItemType Directory -Path $brokenReleaseDir -Force | Out-Null
        New-Item -ItemType Directory -Path $releaseStateDir -Force | Out-Null
        New-Item -ItemType Directory -Path $releaseCommandDir -Force | Out-Null

        $sourceExe = $null
        foreach ($candidate in @("tar.exe", "curl.exe")) {
            $command = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($command -and $command.CommandType -eq "Application" -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
                $sourceExe = $command.Source
                break
            }
        }
        if ([string]::IsNullOrWhiteSpace($sourceExe)) {
            throw "Missing tar.exe/curl.exe; cannot build smoke release assets."
        }
        Copy-Item $sourceExe (Join-Path $releaseDir "codex-x86_64-pc-windows-msvc.exe") -Force
        Copy-Item $sourceExe (Join-Path $releaseDir "codex-command-runner.exe") -Force
        Copy-Item $sourceExe (Join-Path $releaseDir "codex-windows-sandbox-setup.exe") -Force
        Copy-Item $sourceExe (Join-Path $brokenReleaseDir "codex-x86_64-pc-windows-msvc.exe") -Force

        $zipPath = Join-Path $releaseDir "codex-x86_64-pc-windows-msvc.exe.zip"
        if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
        Push-Location $releaseDir
        Compress-Archive -Path @("codex-x86_64-pc-windows-msvc.exe", "codex-command-runner.exe", "codex-windows-sandbox-setup.exe") -DestinationPath $zipPath -Force
        Pop-Location

        $brokenZipPath = Join-Path $brokenReleaseDir "codex-x86_64-pc-windows-msvc.exe.zip"
        if (Test-Path $brokenZipPath) { Remove-Item -Force $brokenZipPath }
        Push-Location $brokenReleaseDir
        Compress-Archive -Path @("codex-x86_64-pc-windows-msvc.exe") -DestinationPath $brokenZipPath -Force
        Pop-Location

        $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $releasePort = $listener.LocalEndpoint.Port
        $listener.Stop()
        $releaseServer = Start-Process -FilePath python -ArgumentList @("-m", "http.server", "$releasePort", "--bind", "127.0.0.1", "--directory", "$assetsDir") -PassThru -NoNewWindow
        $brokenListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $brokenListener.Start()
        $brokenReleasePort = $brokenListener.LocalEndpoint.Port
        $brokenListener.Stop()
        $brokenServer = Start-Process -FilePath python -ArgumentList @("-m", "http.server", "$brokenReleasePort", "--bind", "127.0.0.1", "--directory", (Join-Path $tempRoot 'broken-release-assets')) -PassThru -NoNewWindow
        try {
            for ($i = 0; $i -lt 50; $i++) {
                try {
                    Invoke-WebRequest -Uri "http://127.0.0.1:$releasePort/" -UseBasicParsing | Out-Null
                    break
                } catch {
                    Start-Sleep -Milliseconds 100
                }
            }
            for ($i = 0; $i -lt 50; $i++) {
                try {
                    Invoke-WebRequest -Uri "http://127.0.0.1:$brokenReleasePort/" -UseBasicParsing | Out-Null
                    break
                } catch {
                    Start-Sleep -Milliseconds 100
                }
            }

            $env:HODEX_RELEASE_BASE_URL = "http://127.0.0.1:$releasePort"
            $releaseInstallOutput = (& $runner -NoProfile -File $controllerPath install -Yes -NoPathUpdate -StateDir $releaseStateDir -CommandDir $releaseCommandDir 2>&1 | Out-String)
            if ($releaseInstallOutput -notlike "*Install complete:*") {
                throw "Release install failed unexpectedly:`n$releaseInstallOutput"
            }
            Assert-Contains -Text $releaseInstallOutput -Expected "Install complete:"
            $releaseStatusOutput = (& $runner -NoProfile -File $controllerPath status -StateDir $releaseStateDir 2>&1 | Out-String)
            Assert-Contains -Text $releaseStatusOutput -Expected "Windows runtime components: complete"
            Assert-Contains -Text $releaseStatusOutput -Expected "codex-command-runner.exe: installed"
            Assert-Contains -Text $releaseStatusOutput -Expected "codex-windows-sandbox-setup.exe: installed"
            if (!(Test-Path (Join-Path $releaseCommandDir "hodex.cmd"))) { throw "release hodex.cmd was not created" }
            if (!(Test-Path (Join-Path $releaseCommandDir "hodexctl.cmd"))) { throw "release hodexctl.cmd was not created" }
            if (!(Test-Path (Join-Path $releaseStateDir "bin\codex-command-runner.exe"))) { throw "release codex-command-runner.exe was not created" }
            if (!(Test-Path (Join-Path $releaseStateDir "bin\codex-windows-sandbox-setup.exe"))) { throw "release codex-windows-sandbox-setup.exe was not created" }

            $releaseUninstallOutput = (& $runner -NoProfile -File $controllerPath uninstall -StateDir $releaseStateDir 2>&1 | Out-String)
            Assert-Contains -Text $releaseUninstallOutput -Expected "Removed release binary, wrappers, and install state."
            if (Test-Path (Join-Path $releaseCommandDir "hodex.cmd")) { throw "release hodex.cmd was not deleted" }
            if (Test-Path (Join-Path $releaseCommandDir "hodexctl.cmd")) { throw "release hodexctl.cmd was not deleted" }
            if (Test-Path (Join-Path $releaseStateDir "state.json")) { throw "release state.json was not deleted" }
            if (Test-Path (Join-Path $releaseStateDir "bin\codex-command-runner.exe")) { throw "release codex-command-runner.exe was not deleted" }
            if (Test-Path (Join-Path $releaseStateDir "bin\codex-windows-sandbox-setup.exe")) { throw "release codex-windows-sandbox-setup.exe was not deleted" }

            Write-Host "==> Check Windows repair backfills user PATH"
            $repairStateDir = Join-Path $tempRoot 'repair-state'
            $repairCommandDir = Join-Path $tempRoot 'repair-command'
            New-Item -ItemType Directory -Path $repairStateDir -Force | Out-Null
            New-Item -ItemType Directory -Path $repairCommandDir -Force | Out-Null
            $originalUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
            try {
                $repairInstallOutput = (& $runner -NoProfile -File $controllerPath install -Yes -NoPathUpdate -StateDir $repairStateDir -CommandDir $repairCommandDir 2>&1 | Out-String)
                Assert-Contains -Text $repairInstallOutput -Expected "Install complete:"
                $repairStatusOutput = (& $runner -NoProfile -File $controllerPath status -StateDir $repairStateDir -CommandDir $repairCommandDir 2>&1 | Out-String)
                Assert-Contains -Text $repairStatusOutput -Expected "Recommended: run hodexctl repair"
                $repairOutput = (& $runner -NoProfile -File $controllerPath repair -Yes -StateDir $repairStateDir -CommandDir $repairCommandDir 2>&1 | Out-String)
                if ($LASTEXITCODE -ne 0) { throw "repair failed: $repairOutput" }
                $updatedUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($updatedUserPath -notlike "*$repairCommandDir*") { throw "repair did not write to user PATH" }
                $repairShellOutput = (& $runner -NoProfile -Command @"
`$env:Path = [Environment]::GetEnvironmentVariable('Path', 'User')
`$hodexSource = (Get-Command hodex -ErrorAction Stop).Source
Write-Output `$hodexSource
& hodex --version
"@ 2>&1 | Out-String)
                if ($LASTEXITCODE -ne 0) { throw "repair shell validation failed: $repairShellOutput" }
                Assert-Contains -Text $repairShellOutput -Expected $repairCommandDir
            } finally {
                [Environment]::SetEnvironmentVariable("Path", $originalUserPath, "User")
            }

            Write-Host "==> Check Windows preexisting user PATH is not removed on uninstall"
            $preexistingStateDir = Join-Path $tempRoot 'preexisting-state'
            $preexistingCommandDir = Join-Path $tempRoot 'preexisting-command'
            New-Item -ItemType Directory -Path $preexistingStateDir -Force | Out-Null
            New-Item -ItemType Directory -Path $preexistingCommandDir -Force | Out-Null
            $originalUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
            $originalProcessPath = $env:Path
            try {
                [Environment]::SetEnvironmentVariable("Path", (Add-PathEntry -PathValue $originalUserPath -Entry $preexistingCommandDir), "User")
                $env:Path = Remove-PathEntry -PathValue $originalProcessPath -Entry $preexistingCommandDir
                $preexistingInstallOutput = (& $runner -NoProfile -File $controllerPath install -Yes -StateDir $preexistingStateDir -CommandDir $preexistingCommandDir 2>&1 | Out-String)
                Assert-Contains -Text $preexistingInstallOutput -Expected "Install complete:"
                $preexistingStatusOutput = (& $runner -NoProfile -File $controllerPath status -StateDir $preexistingStateDir -CommandDir $preexistingCommandDir 2>&1 | Out-String)
                Assert-Contains -Text $preexistingStatusOutput -Expected "PATH source: preexisting-user-path"
                $preexistingUninstallOutput = (& $runner -NoProfile -File $controllerPath uninstall -StateDir $preexistingStateDir 2>&1 | Out-String)
                Assert-Contains -Text $preexistingUninstallOutput -Expected "Removed release binary, wrappers, and install state."
                $userPathAfterUninstall = [Environment]::GetEnvironmentVariable("Path", "User")
                if ($userPathAfterUninstall -notlike "*$preexistingCommandDir*") { throw "Uninstall removed preexisting user PATH entry" }
	            } finally {
	                [Environment]::SetEnvironmentVariable("Path", $originalUserPath, "User")
	                $env:Path = $originalProcessPath
	            }

	            Write-Host "==> Check Windows legacy state.json uninstall still cleans user PATH"
	            $legacyStateDir = Join-Path $tempRoot 'legacy-state'
	            $legacyCommandDir = Join-Path $tempRoot 'legacy-command'
	            New-Item -ItemType Directory -Path $legacyStateDir -Force | Out-Null
	            New-Item -ItemType Directory -Path $legacyCommandDir -Force | Out-Null
	            $legacyControllerPath = Join-Path $legacyStateDir 'libexec\hodexctl.ps1'
	            New-Item -ItemType Directory -Path (Split-Path -Parent $legacyControllerPath) -Force | Out-Null
	            Copy-Item -LiteralPath $controllerPath -Destination $legacyControllerPath -Force

	            $legacyStatePayload = [ordered]@{
	                schema_version    = 2
	                repo              = 'stellarlinkco/codex'
	                installed_version = ''
	                release_tag       = ''
	                release_name      = ''
	                asset_name        = ''
	                binary_path       = ''
	                controller_path   = $legacyControllerPath
	                command_dir       = $legacyCommandDir
	                wrappers_created  = @()
	                path_update_mode  = 'added'
	                path_profile      = 'User'
	                node_setup_choice = ''
	                installed_at      = '2026-03-09T00:00:00Z'
	                source_profiles   = [ordered]@{}
	                active_runtime_aliases = [ordered]@{}
	            }
	            ($legacyStatePayload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath (Join-Path $legacyStateDir 'state.json') -Encoding UTF8

	            $originalUserPath = [Environment]::GetEnvironmentVariable("Path", "User")
	            $originalProcessPath = $env:Path
	            try {
	                [Environment]::SetEnvironmentVariable("Path", (Add-PathEntry -PathValue $originalUserPath -Entry $legacyCommandDir), "User")
	                $env:Path = Add-PathEntry -PathValue $originalProcessPath -Entry $legacyCommandDir

	                $legacyUninstallOutput = (& $runner -NoProfile -File $controllerPath uninstall -StateDir $legacyStateDir 2>&1 | Out-String)
	                Assert-Contains -Text $legacyUninstallOutput -Expected "hodexctl manager uninstalled."
	                $userPathAfterUninstall = [Environment]::GetEnvironmentVariable("Path", "User")
	                if ($userPathAfterUninstall -like "*$legacyCommandDir*") { throw "Legacy state.json uninstall left user PATH entry" }
	            } finally {
	                [Environment]::SetEnvironmentVariable("Path", $originalUserPath, "User")
	                $env:Path = $originalProcessPath
	            }

	            Write-Host "==> Check Windows missing helper fails strictly"
	            $env:HODEX_RELEASE_BASE_URL = "http://127.0.0.1:$brokenReleasePort"
	            $brokenInstallResult = Invoke-RunnerCapture -Runner $runner -ArgumentList @(
	                "-NoProfile",
	                "-ExecutionPolicy", "Bypass",
	                "-File", $controllerPath,
	                "install",
	                "-Yes",
	                "-NoPathUpdate",
	                "-StateDir", (Join-Path $tempRoot 'broken-state'),
	                "-CommandDir", (Join-Path $tempRoot 'broken-command')
	            )
	            if ($brokenInstallResult.ExitCode -eq 0) { throw "Windows release install with missing helper should not succeed" }
            Assert-Contains -Text $brokenInstallResult.StdErr -Expected "Windows release asset missing required helper"
        } finally {
            try { if ($releaseServer -and -not $releaseServer.HasExited) { $releaseServer.Kill() } } catch {}
            try { if ($brokenServer -and -not $brokenServer.HasExited) { $brokenServer.Kill() } } catch {}
            Remove-Item Env:\HODEX_RELEASE_BASE_URL -ErrorAction SilentlyContinue
        }

        Write-Host "==> Check source empty state output"
        $sourceStatusOutput = (& $runner -NoProfile -File $controllerPath source status -StateDir $smokeStateDir 2>&1 | Out-String)
        $sourceListOutput = (& $runner -NoProfile -File $controllerPath source list -StateDir $smokeStateDir 2>&1 | Out-String)
        Assert-Contains -Text $sourceStatusOutput -Expected "No source profiles installed"
        Assert-Contains -Text $sourceListOutput -Expected "No source profiles recorded"

        Write-Host "==> Check source mode local loopback sync"
        if ((Get-Command git -ErrorAction SilentlyContinue) -and (Get-Command cargo -ErrorAction SilentlyContinue) -and (Get-Command rustc -ErrorAction SilentlyContinue) -and (Get-Command link.exe -ErrorAction SilentlyContinue)) {
            New-Item -ItemType Directory -Path (Join-Path $sourceRepoDir "src") -Force | Out-Null
            New-Item -ItemType Directory -Path $smokeCommandDir -Force | Out-Null

            Set-Content -Path (Join-Path $sourceRepoDir "Cargo.toml") -Value @"
[package]
name = "codex-cli"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "codex"
path = "src/main.rs"
"@
            Set-Content -Path (Join-Path $sourceRepoDir "src/main.rs") -Value @"
fn main() {
    println!("smoke-build 0.1.0");
}
"@

            & git -C $sourceRepoDir init -b main | Out-Null
            & git -C $sourceRepoDir config user.name "hodexctl-smoke" | Out-Null
            & git -C $sourceRepoDir config user.email "hodexctl-smoke@example.com" | Out-Null
            & git -C $sourceRepoDir add Cargo.toml src/main.rs | Out-Null
            & git -C $sourceRepoDir commit -m "init smoke repo" | Out-Null
            & git -C $sourceRepoDir tag smoke-tag | Out-Null

            $sourceInstallOutput = (& $runner -NoProfile -File $controllerPath source install -Yes -NoPathUpdate -StateDir $smokeStateDir -CommandDir $smokeCommandDir -GitUrl $sourceRepoDir -Profile smoke-source -Ref main -CheckoutDir $smokeSourceCheckoutDir 2>&1 | Out-String)
            Assert-Contains -Text $sourceInstallOutput -Expected "Result summary"
            Assert-Contains -Text $sourceInstallOutput -Expected "Source profile: smoke-source"
            if (!(Test-Path (Join-Path $smokeSourceCheckoutDir ".git"))) { throw "Source checkout was not created" }
            if (!(Test-Path (Join-Path $smokeCommandDir "hodexctl.cmd"))) { throw "hodexctl wrapper was not created" }
            $checkoutHead = (& git -C $smokeSourceCheckoutDir rev-parse HEAD | Out-String).Trim()
            $repoHead = (& git -C $sourceRepoDir rev-parse HEAD | Out-String).Trim()
            if ($checkoutHead -ne $repoHead) { throw "Source install checkout HEAD mismatch" }

            $sourceStatusOutput = (& $runner -NoProfile -File $controllerPath source status -Yes -NoPathUpdate -StateDir $smokeStateDir -CommandDir $smokeCommandDir 2>&1 | Out-String)
            Assert-Contains -Text $sourceStatusOutput -Expected "Name: smoke-source"
            Assert-Contains -Text $sourceStatusOutput -Expected "Mode: manage checkout and toolchain only; no source command wrappers generated"

            Set-Content -Path (Join-Path $sourceRepoDir "src/main.rs") -Value @"
fn main() {
    println!("smoke-build 0.2.0");
}
"@
            & git -C $sourceRepoDir add src/main.rs | Out-Null
            & git -C $sourceRepoDir commit -m "update smoke repo" | Out-Null

            $sourceUpdateOutput = (& $runner -NoProfile -File $controllerPath source update -Yes -NoPathUpdate -StateDir $smokeStateDir -CommandDir $smokeCommandDir 2>&1 | Out-String)
            Assert-Contains -Text $sourceUpdateOutput -Expected "Action: Update source"
            $checkoutHead = (& git -C $smokeSourceCheckoutDir rev-parse HEAD | Out-String).Trim()
            $repoHead = (& git -C $sourceRepoDir rev-parse HEAD | Out-String).Trim()
            if ($checkoutHead -ne $repoHead) { throw "Source update checkout HEAD mismatch" }

            & git -C $sourceRepoDir checkout -b feature-smoke-switch | Out-Null
            $env:HODEXCTL_SKIP_MAIN = "1"
            . $controllerPath
            Remove-Item Env:\HODEXCTL_SKIP_MAIN -ErrorAction SilentlyContinue
            $refCandidates = @(Get-SourceRefCandidates -RepoInput $sourceRepoDir -ProfileName "smoke-source" -DefaultRef "main" -CheckoutDir $smokeSourceCheckoutDir)
            if ($refCandidates -notcontains "feature-smoke-switch") { throw "Git refs were not included in source ref candidates" }
            if ($refCandidates -contains "smoke-tag") { throw "Branch candidates should not include tags by default" }

            $sourceSwitchOutput = (& $runner -NoProfile -File $controllerPath source switch -Yes -NoPathUpdate -StateDir $smokeStateDir -CommandDir $smokeCommandDir -Ref feature-smoke-switch 2>&1 | Out-String)
            Assert-Contains -Text $sourceSwitchOutput -Expected "Action: Switch ref and sync source"
            $currentBranch = (& git -C $smokeSourceCheckoutDir rev-parse --abbrev-ref HEAD | Out-String).Trim()
            if ($currentBranch -ne "feature-smoke-switch") { throw "Source switch ref branch mismatch" }

            $sourceRebuildOutput = (& $runner -NoProfile -File $controllerPath source rebuild -Yes -NoPathUpdate -StateDir $smokeStateDir -CommandDir $smokeCommandDir 2>&1 | Out-String)
            Assert-Contains -Text $sourceRebuildOutput -Expected "source rebuild has been removed"

            $sourceUninstallOutput = (& $runner -NoProfile -File $controllerPath source uninstall -Yes -NoPathUpdate -KeepCheckout -StateDir $smokeStateDir -CommandDir $smokeCommandDir 2>&1 | Out-String)
            Assert-Contains -Text $sourceUninstallOutput -Expected "Source profile uninstalled"
            if (!(Test-Path $smokeSourceCheckoutDir)) { throw "Source checkout should not be deleted" }
            if (Test-Path (Join-Path $smokeCommandDir "hodexctl.cmd")) { throw "hodexctl wrapper was not deleted" }
        } else {
            Write-Host "==> Missing git/cargo/rustc/link.exe; skip source loopback integration test"
        }
    } else {
        Write-Host "==> Non-Windows environment; skip runtime checks"
    }

    Write-Host "==> Smoke test passed"
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
