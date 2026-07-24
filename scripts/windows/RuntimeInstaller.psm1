Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:InstallerLogPath = $null
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:DiscoveryRegistryValueNames = @(
    'InstallPath',
    'PythonExecutable',
    'PythonVersion',
    'InstallerVersion',
    'ManifestPath',
)

function Initialize-InstallerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LogDirectory,
        [string]$Operation = 'install'
    )

    [System.IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
    $timestamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $script:InstallerLogPath = Join-Path $LogDirectory ("installer-{0}-{1}.log" -f $Operation, $timestamp)
    [System.IO.File]::WriteAllText($script:InstallerLogPath, '', $script:Utf8NoBom)

    $historicalLogs = @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'installer-*.log' -File |
        Where-Object FullName -NE $script:InstallerLogPath |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($historicalLogs.Count -gt 19) {
        $historicalLogs | Select-Object -Skip 19 | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    Write-InstallerLog -Stage 'logging' -Message ("Log initialized: {0}" -f $script:InstallerLogPath)
    return $script:InstallerLogPath
}

function Write-InstallerLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    if ([string]::IsNullOrWhiteSpace($script:InstallerLogPath)) {
        throw 'Initialize-InstallerLog must be called before writing logs.'
    }
    $safeMessage = $Message.Replace("`r", ' ').Replace("`n", ' ')
    $line = "{0} [{1}] [{2}] {3}{4}" -f [DateTime]::UtcNow.ToString('o'), $Level, $Stage, $safeMessage, [Environment]::NewLine
    [System.IO.File]::AppendAllText($script:InstallerLogPath, $line, $script:Utf8NoBom)
}

function Get-InstallerLogPath {
    return $script:InstallerLogPath
}

function Protect-InstallerDiagnosticText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $safeText = $Text.Replace("`r", ' ').Replace("`n", ' ')
    return [regex]::Replace(
        $safeText,
        '(?i)\b(token|password|passwd|secret|api[_-]?key)\s*[:=]\s*[^\s;]+',
        '$1=<redacted>'
    )
}

function ConvertTo-InstallerAsciiDiagnosticText {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Fallback
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Fallback
    }
    if ($Text -match '[^\x09\x0A\x0D\x20-\x7E]') {
        return $Fallback
    }
    return Protect-InstallerDiagnosticText -Text $Text
}

function Format-InstallerErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exceptionType = ConvertTo-InstallerAsciiDiagnosticText `
        -Text $ErrorRecord.Exception.GetType().FullName `
        -Fallback '<unknown>'
    $errorId = ConvertTo-InstallerAsciiDiagnosticText `
        -Text ([string]$ErrorRecord.FullyQualifiedErrorId) `
        -Fallback '<unknown>'
    $commandName = '<unknown>'
    $scriptLine = 0
    if ($ErrorRecord.InvocationInfo) {
        $scriptLine = $ErrorRecord.InvocationInfo.ScriptLineNumber
        if ($ErrorRecord.InvocationInfo.MyCommand) {
            $commandName = ConvertTo-InstallerAsciiDiagnosticText `
                -Text ([string]$ErrorRecord.InvocationInfo.MyCommand.Name) `
                -Fallback '<localized-or-non-ascii-command-omitted>'
        }
    }
    $message = ConvertTo-InstallerAsciiDiagnosticText `
        -Text ([string]$ErrorRecord.Exception.Message) `
        -Fallback '<localized-or-non-ascii-text-omitted>'

    return (
        'ExceptionType={0}; ErrorId={1}; Command={2}; ScriptLine={3}; Message={4}' -f
        $exceptionType,
        $errorId,
        $commandName,
        $scriptLine,
        $message
    )
}

function ConvertTo-ProcessArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashCount += 1
            continue
        }
        if ($character -eq [char]34) {
            if ($backslashCount -gt 0) {
                [void]$builder.Append(([string][char]92) * ($backslashCount * 2))
            }
            [void]$builder.Append('\"')
            $backslashCount = 0
            continue
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append(([string][char]92) * $backslashCount)
            $backslashCount = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashCount -gt 0) {
        [void]$builder.Append(([string][char]92) * ($backslashCount * 2))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Invoke-LoggedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [Parameter(Mandatory = $true)][string]$Stage,
        [string]$WorkingDirectory = '',
        [int[]]$AllowedExitCodes = @(0),
        [switch]$EmitHeartbeat,
        [ValidateRange(1, 60)][int]$HeartbeatIntervalSeconds = 5,
        [ValidateRange(1, 120)][int]$OutputDrainTimeoutSeconds = 15
    )

    $argumentString = (($Arguments | ForEach-Object { ConvertTo-ProcessArgument -Value $_ }) -join ' ')
    Write-InstallerLog -Stage $Stage -Message ("Executing {0} {1}" -f $FilePath, $argumentString)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $argumentString
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $environmentNames = @($startInfo.EnvironmentVariables.Keys | ForEach-Object { [string]$_ })
    foreach ($environmentName in $environmentNames) {
        if (
            [StringComparer]::OrdinalIgnoreCase.Equals($environmentName, 'ENSUREPIP_OPTIONS') -or
            $environmentName.StartsWith('PIP_', [StringComparison]::OrdinalIgnoreCase)
        ) {
            [void]$startInfo.EnvironmentVariables.Remove($environmentName)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $startInfo.WorkingDirectory = $WorkingDirectory
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Failed to start process: $FilePath"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextHeartbeat = $HeartbeatIntervalSeconds
    $heartbeatOutputAvailable = $true
    $outputDrainDeadline = $null
    while ($true) {
        if (-not $process.HasExited) {
            [void]$process.WaitForExit(250)
        } elseif ($null -eq $outputDrainDeadline) {
            $process.WaitForExit()
            $outputDrainDeadline = [DateTime]::UtcNow.AddSeconds($OutputDrainTimeoutSeconds)
        }
        if ($process.HasExited -and $stdoutTask.IsCompleted -and $stderrTask.IsCompleted) {
            break
        }
        if ($outputDrainDeadline -and [DateTime]::UtcNow -ge $outputDrainDeadline) {
            throw "Process output did not close within $OutputDrainTimeoutSeconds seconds: $FilePath"
        }
        if ($EmitHeartbeat -and $stopwatch.Elapsed.TotalSeconds -ge $nextHeartbeat) {
            if ($heartbeatOutputAvailable) {
                $heartbeat = "PYRUNTIME_HEARTBEAT|{0}|{1}" -f @(
                    $Stage,
                    [Math]::Floor($stopwatch.Elapsed.TotalSeconds)
                )
                try {
                    [Console]::Out.WriteLine($heartbeat)
                    [Console]::Out.Flush()
                } catch {
                    $heartbeatOutputAvailable = $false
                    Write-InstallerLog -Stage $Stage -Level 'WARN' -Message (
                        'Progress heartbeat output became unavailable; the managed process will continue.'
                    )
                }
            }
            $nextHeartbeat += $HeartbeatIntervalSeconds
        }
        if ($process.HasExited) {
            Start-Sleep -Milliseconds 250
        }
    }
    $stopwatch.Stop()
    $stdout = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        Write-InstallerLog -Stage $Stage -Message ("stdout: {0}" -f $stdout.Trim())
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        Write-InstallerLog -Stage $Stage -Level 'WARN' -Message ("stderr: {0}" -f $stderr.Trim())
    }
    Write-InstallerLog -Stage $Stage -Message ("Exit code: {0}" -f $process.ExitCode)
    if ($AllowedExitCodes -notcontains $process.ExitCode) {
        throw "Process failed with exit code $($process.ExitCode): $FilePath"
    }
    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Get-ProductConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        throw "Product configuration not found: $ConfigPath"
    }
    return Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-NativeWindowsArchitecture {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        return $env:PROCESSOR_ARCHITEW6432.ToUpperInvariant()
    }
    if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITECTURE)) {
        return $env:PROCESSOR_ARCHITECTURE.ToUpperInvariant()
    }

    $systemEnvironment = Get-ItemProperty `
        -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' `
        -Name 'PROCESSOR_ARCHITECTURE' `
        -ErrorAction Stop
    $architecture = [string]$systemEnvironment.PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrWhiteSpace($architecture)) {
        throw 'Unable to determine the native Windows architecture.'
    }
    return $architecture.ToUpperInvariant()
}

function Test-WindowsServerE2EOverrideAllowed {
    [CmdletBinding()]
    param(
        [switch]$Requested,
        [AllowEmptyString()][string]$GitHubActions = $env:GITHUB_ACTIONS,
        [AllowEmptyString()][string]$RunnerEnvironment = $env:RUNNER_ENVIRONMENT
    )

    return (
        $Requested.IsPresent -and
        [StringComparer]::OrdinalIgnoreCase.Equals($GitHubActions, 'true') -and
        [StringComparer]::OrdinalIgnoreCase.Equals($RunnerEnvironment, 'github-hosted')
    )
}

function Assert-WindowsPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][Int64]$MinimumFreeBytes,
        [switch]$AllowWindowsServerForE2E
    )

    $version = [Environment]::OSVersion.Version
    if ($version.Major -lt 10) {
        throw "Unsupported Windows version: $version"
    }
    $productName = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name ProductName -ErrorAction Stop).ProductName
    $serverE2EOverrideAllowed = Test-WindowsServerE2EOverrideAllowed -Requested:$AllowWindowsServerForE2E
    if ($AllowWindowsServerForE2E -and -not $serverE2EOverrideAllowed) {
        throw 'The Windows Server E2E preflight override requires a GitHub-hosted Actions runner.'
    }
    if ($serverE2EOverrideAllowed -and $productName -notmatch 'Server') {
        throw "The Windows Server E2E preflight override is only valid on Windows Server: $productName"
    }
    if ($productName -match 'Server' -and -not $serverE2EOverrideAllowed) {
        throw "Windows Server is not a supported target: $productName"
    }
    $architecture = Get-NativeWindowsArchitecture
    if ($architecture -ne 'AMD64') {
        throw "Unsupported Windows architecture: $architecture"
    }
    $pathRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($AppRoot))
    $drive = New-Object System.IO.DriveInfo($pathRoot)
    if ($drive.AvailableFreeSpace -lt $MinimumFreeBytes) {
        throw "Insufficient disk space. Required=$MinimumFreeBytes Available=$($drive.AvailableFreeSpace)"
    }
    Write-InstallerLog -Stage 'preflight' -Message ("Supported host: {0}; arch={1}; free={2}; windows_server_e2e_override={3}" -f $productName, $architecture, $drive.AvailableFreeSpace, $serverE2EOverrideAllowed)
}

function Test-IsCandidatePathAllowed {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PythonPath)
    $normalized = $PythonPath.ToLowerInvariant()
    foreach ($blocked in @('\windowsapps\', '\anaconda', '\miniconda', '\conda\', '\embedded\')) {
        if ($normalized.Contains($blocked)) {
            return $false
        }
    }
    return $true
}

function Test-CompatiblePython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PythonPath,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
        return $false
    }
    if (-not (Test-IsCandidatePathAllowed -PythonPath $PythonPath)) {
        return $false
    }
    $probe = 'import json,platform,ssl,sys,venv,ensurepip;print(json.dumps({"implementation":sys.implementation.name,"version":platform.python_version(),"bits":platform.architecture()[0],"ssl":ssl.OPENSSL_VERSION}))'
    try {
        $result = Invoke-LoggedProcess -FilePath $PythonPath -Arguments @('-I', '-c', $probe) -Stage 'python-probe'
        $data = $result.StdOut.Trim() | ConvertFrom-Json
        if ($data.implementation -ne 'cpython' -or $data.version -ne $ExpectedVersion -or $data.bits -ne '64bit') {
            return $false
        }
        $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("PythonRuntimeInstaller-Probe-{0}" -f [Guid]::NewGuid().ToString('N'))
        try {
            Invoke-LoggedProcess -FilePath $PythonPath -Arguments @('-I', '-m', 'venv', $probeRoot) -Stage 'python-probe' | Out-Null
            $probePython = Join-Path $probeRoot 'Scripts\python.exe'
            Invoke-LoggedProcess -FilePath $probePython -Arguments @('-I', '-c', 'import ensurepip,ssl,venv;print("healthy")') -Stage 'python-probe' | Out-Null
        } finally {
            if (Test-Path -LiteralPath $probeRoot) {
                Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        return $true
    } catch {
        $diagnostic = Format-InstallerErrorRecord -ErrorRecord $_
        Write-InstallerLog -Stage 'python-probe' -Level 'WARN' -Message ("Candidate rejected: {0}; {1}" -f $PythonPath, $diagnostic)
        return $false
    }
}

function Get-RegisteredPythonCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegistryBase,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $registeredCandidates = @()
    if (-not (Test-Path -LiteralPath $RegistryBase)) {
        return @()
    }
    $expectedMajorMinor = ([Version]$ExpectedVersion).ToString(2)
    foreach ($tagKey in @(Get-ChildItem -LiteralPath $RegistryBase -ErrorAction SilentlyContinue)) {
        $isExactRegistration = $false
        try {
            $tagProperties = Get-ItemProperty -LiteralPath $tagKey.PSPath -ErrorAction Stop
            $sysVersionProperty = $tagProperties.PSObject.Properties['SysVersion']
            if ($sysVersionProperty -and $sysVersionProperty.Value) {
                $registeredVersion = [string]$sysVersionProperty.Value
                if ($registeredVersion -eq $ExpectedVersion) {
                    $isExactRegistration = $true
                } elseif ($registeredVersion -ne $expectedMajorMinor) {
                    continue
                }
            }
            $installPathKey = Join-Path $tagKey.PSPath 'InstallPath'
            if (-not (Test-Path -LiteralPath $installPathKey)) {
                continue
            }
            $installProperties = Get-ItemProperty -LiteralPath $installPathKey -ErrorAction Stop
            $executableProperty = $installProperties.PSObject.Properties['ExecutablePath']
            $installPath = $null
            if (-not ($executableProperty -and $executableProperty.Value)) {
                $installPath = (Get-Item -LiteralPath $installPathKey -ErrorAction Stop).GetValue('')
            }
            $candidate = if ($executableProperty -and $executableProperty.Value) {
                $executableProperty.Value
            } elseif ($installPath) {
                Join-Path ([string]$installPath) 'python.exe'
            } else {
                $null
            }
            if ($candidate) {
                $registeredCandidates += [PSCustomObject]@{ Path = [string]$candidate; Exact = $isExactRegistration }
            }
        } catch {
            $diagnostic = Format-InstallerErrorRecord -ErrorRecord $_
            Write-InstallerLog -Stage 'python-discovery' -Level 'WARN' -Message ("Registry candidate ignored: {0}; {1}" -f $tagKey.PSPath, $diagnostic)
        }
    }
    return @($registeredCandidates | Sort-Object Exact -Descending | Select-Object -ExpandProperty Path -Unique)
}

function Get-PythonCandidate {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ExpectedVersion)

    $candidates = New-Object System.Collections.Generic.List[string]
    $registryBases = @(
        'HKCU:\Software\Python\PythonCore',
        'HKLM:\Software\Python\PythonCore',
        'HKLM:\Software\WOW6432Node\Python\PythonCore'
    )
    foreach ($registryBase in $registryBases) {
        foreach ($candidate in @(Get-RegisteredPythonCandidate -RegistryBase $registryBase -ExpectedVersion $ExpectedVersion)) {
            $candidates.Add($candidate)
        }
    }
    $launcher = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($launcher -and -not $launcher.Source.ToLowerInvariant().Contains('\windowsapps\')) {
        try {
            $launcherResult = Invoke-LoggedProcess -FilePath $launcher.Source -Arguments @('-0p') -Stage 'python-discovery'
            foreach ($line in $launcherResult.StdOut -split "`r?`n") {
                if ($line -match '([A-Za-z]:\\.*python\.exe)\s*$') {
                    $candidates.Add($Matches[1].Trim())
                }
            }
        } catch {
            Write-InstallerLog -Stage 'python-discovery' -Level 'WARN' -Message (
                Format-InstallerErrorRecord -ErrorRecord $_
            )
        }
    }
    return @($candidates | Select-Object -Unique)
}

function Find-CompatiblePython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [string]$ManagedRoot = '',
        [switch]$ForceBundled
    )

    if ($ForceBundled) {
        Write-InstallerLog -Stage 'python-discovery' -Message 'Bundled runtime forced for test.'
        return $null
    }
    foreach ($candidate in Get-PythonCandidate -ExpectedVersion $ExpectedVersion) {
        if (-not [string]::IsNullOrWhiteSpace($ManagedRoot)) {
            try {
                $managedPrefix = [System.IO.Path]::GetFullPath($ManagedRoot).TrimEnd('\') + '\'
                $candidatePath = [System.IO.Path]::GetFullPath($candidate)
            } catch {
                Write-InstallerLog -Stage 'python-discovery' -Level 'WARN' -Message ("Invalid candidate path rejected: {0}" -f $candidate)
                continue
            }
            if ($candidatePath.StartsWith($managedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                Write-InstallerLog -Stage 'python-discovery' -Level 'WARN' -Message ("Unowned managed-path candidate rejected: {0}" -f $candidate)
                continue
            }
        }
        if (Test-CompatiblePython -PythonPath $candidate -ExpectedVersion $ExpectedVersion) {
            Write-InstallerLog -Stage 'python-discovery' -Message ("Reusable CPython selected: {0}" -f $candidate)
            return $candidate
        }
    }
    Write-InstallerLog -Stage 'python-discovery' -Message 'No reusable CPython candidate passed health checks.'
    return $null
}

function Install-PrivatePython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstallerPath,
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion
    )

    $runtimeRoot = Join-Path $AppRoot ("runtime\{0}" -f $ExpectedVersion)
    $pythonPath = Join-Path $runtimeRoot 'python.exe'
    if (Test-CompatiblePython -PythonPath $pythonPath -ExpectedVersion $ExpectedVersion) {
        return [PSCustomObject]@{ PythonPath = $pythonPath; NewlyInstalled = $false }
    }
    $runtimeExisted = Test-Path -LiteralPath $runtimeRoot
    [System.IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
    $maintenanceRoot = Join-Path $AppRoot 'maintenance'
    [System.IO.Directory]::CreateDirectory($maintenanceRoot) | Out-Null
    $savedInstaller = Join-Path $maintenanceRoot ([System.IO.Path]::GetFileName($InstallerPath))
    Copy-Item -LiteralPath $InstallerPath -Destination $savedInstaller -Force
    try {
        $arguments = @(
            '/quiet',
            'InstallAllUsers=0',
            ("TargetDir={0}" -f $runtimeRoot),
            'Include_launcher=0',
            'InstallLauncherAllUsers=0',
            'AssociateFiles=0',
            'Shortcuts=0',
            'PrependPath=0',
            'AppendPath=0',
            'Include_test=0',
            'Include_doc=0',
            'Include_debug=0',
            'Include_symbols=0',
            'Include_pip=1',
            'Include_dev=1',
            'Include_exe=1',
            'Include_lib=1',
            'Include_tools=1',
            'Include_tcltk=1'
        )
        Invoke-LoggedProcess -FilePath $savedInstaller -Arguments $arguments -Stage 'python-install' -AllowedExitCodes @(0, 3010) -EmitHeartbeat | Out-Null
        if (-not (Test-CompatiblePython -PythonPath $pythonPath -ExpectedVersion $ExpectedVersion)) {
            throw "Private CPython failed post-install health check: $pythonPath"
        }
    } catch {
        if (-not $runtimeExisted) {
            Uninstall-PrivatePython -AppRoot $AppRoot -InstallerFilename ([System.IO.Path]::GetFileName($InstallerPath))
            if (Test-Path -LiteralPath $runtimeRoot) {
                Remove-OwnedDirectory -AppRoot $AppRoot -Path $runtimeRoot
            }
        } else {
            Write-InstallerLog -Stage 'python-install' -Level 'WARN' -Message 'Existing owned runtime was retained after a failed repair.'
        }
        throw
    }
    return [PSCustomObject]@{ PythonPath = $pythonPath; NewlyInstalled = (-not $runtimeExisted) }
}

function Uninstall-PrivatePython {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][string]$InstallerFilename
    )
    $savedInstaller = Join-Path (Join-Path $AppRoot 'maintenance') $InstallerFilename
    if (Test-Path -LiteralPath $savedInstaller -PathType Leaf) {
        try {
            Invoke-LoggedProcess -FilePath $savedInstaller -Arguments @('/uninstall', '/quiet') -Stage 'python-uninstall' -AllowedExitCodes @(0, 1605, 3010) -EmitHeartbeat | Out-Null
        } catch {
            Write-InstallerLog -Stage 'python-uninstall' -Level 'WARN' -Message (
                Format-InstallerErrorRecord -ErrorRecord $_
            )
        } finally {
            if (Test-Path -LiteralPath $savedInstaller -PathType Leaf) {
                Remove-Item -LiteralPath $savedInstaller -Force
            }
        }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = $null
    $algorithm = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        $hashBytes = $algorithm.ComputeHash($stream)
        return ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
    } finally {
        if ($algorithm) {
            $algorithm.Dispose()
        }
        if ($stream) {
            $stream.Dispose()
        }
    }
}

function Test-PayloadManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $root = [System.IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\') + '\'
    if (-not $manifest.files -or @($manifest.files).Count -eq 0) {
        throw 'Payload manifest contains no files.'
    }
    $expectedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($manifest.files)) {
        $relativePath = ([string]$entry.path).Replace('\', '/')
        if (-not $expectedPaths.Add($relativePath)) {
            throw "Duplicate payload manifest path: $($entry.path)"
        }
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $PayloadRoot $entry.path))
        if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Payload path escapes root: $($entry.path)"
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "Payload file missing: $($entry.path)"
        }
        $item = Get-Item -LiteralPath $candidate
        if ($item.Length -ne [Int64]$entry.size) {
            throw "Payload size mismatch: $($entry.path)"
        }
        if ((Get-FileSha256 -Path $candidate) -ne $entry.sha256) {
            throw "Payload hash mismatch: $($entry.path)"
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $PayloadRoot -File -Recurse) {
        if ($file.FullName -eq [System.IO.Path]::GetFullPath($ManifestPath)) {
            continue
        }
        $relativePath = $file.FullName.Substring($root.Length).Replace('\', '/')
        if (-not $expectedPaths.Contains($relativePath)) {
            throw "Unexpected unmanifested payload file: $relativePath"
        }
    }
    Write-InstallerLog -Stage 'integrity' -Message ("Verified {0} payload files." -f @($manifest.files).Count)
    return $manifest
}

function Compare-InstallerVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstalledVersion,
        [Parameter(Mandatory = $true)][string]$IncomingVersion
    )
    return ([Version]$InstalledVersion).CompareTo([Version]$IncomingVersion)
}

function Update-VenvActivationPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VenvRoot,
        [Parameter(Mandatory = $true)][string]$OldRoot
    )
    foreach ($relative in @('Scripts\activate', 'Scripts\activate.bat', 'Scripts\Activate.ps1', 'Scripts\activate.fish')) {
        $path = Join-Path $VenvRoot $relative
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            $content = [System.IO.File]::ReadAllText($path)
            $content = $content.Replace($OldRoot, $VenvRoot)
            [System.IO.File]::WriteAllText($path, $content, $script:Utf8NoBom)
        }
    }
}

function Publish-DiscoveryRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][string]$PythonExecutable,
        [Parameter(Mandatory = $true)][string]$PythonVersion,
        [Parameter(Mandatory = $true)][string]$InstallerVersion,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )
    $key = "HKCU:\$RegistryPath"
    New-Item -Path $key -Force | Out-Null
    $values = @{
        InstallPath = $AppRoot
        PythonExecutable = $PythonExecutable
        PythonVersion = $PythonVersion
        InstallerVersion = $InstallerVersion
        ManifestPath = $ManifestPath
    }
    foreach ($name in $script:DiscoveryRegistryValueNames) {
        New-ItemProperty -Path $key -Name $name -Value $values[$name] -PropertyType String -Force | Out-Null
    }
}

function Get-DiscoveryMetadataSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RegistryPath)
    $key = "HKCU:\$RegistryPath"
    if (-not (Test-Path -LiteralPath $key)) {
        return [PSCustomObject]@{ Exists = $false; Values = @{} }
    }
    $item = Get-ItemProperty -LiteralPath $key
    $values = @{}
    foreach ($name in $script:DiscoveryRegistryValueNames) {
        $property = $item.PSObject.Properties[$name]
        if ($property) {
            $values[$name] = [string]$property.Value
        }
    }
    return [PSCustomObject]@{ Exists = $true; Values = $values }
}

function Restore-DiscoveryRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RegistryPath,
        [Parameter(Mandatory = $true)]$Snapshot
    )
    Remove-DiscoveryRegistration -RegistryPath $RegistryPath
    if (-not $Snapshot.Exists) {
        return
    }
    $key = "HKCU:\$RegistryPath"
    New-Item -Path $key -Force | Out-Null
    foreach ($name in $Snapshot.Values.Keys) {
        New-ItemProperty -Path $key -Name $name -Value $Snapshot.Values[$name] -PropertyType String -Force | Out-Null
    }
}

function Remove-DiscoveryRegistration {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RegistryPath)
    $key = "HKCU:\$RegistryPath"
    if (Test-Path -LiteralPath $key) {
        Remove-Item -LiteralPath $key -Recurse -Force
    }
}

function Remove-OwnedDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $root = [System.IO.Path]::GetFullPath($AppRoot).TrimEnd('\') + '\'
    $candidate = [System.IO.Path]::GetFullPath($Path)
    if (-not $candidate.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove path outside application root: $Path"
    }
    if (Test-Path -LiteralPath $candidate) {
        Remove-Item -LiteralPath $candidate -Recurse -Force
    }
}

Export-ModuleMember -Function @(
    'Initialize-InstallerLog',
    'Write-InstallerLog',
    'Get-InstallerLogPath',
    'Format-InstallerErrorRecord',
    'Invoke-LoggedProcess',
    'Get-ProductConfig',
    'Get-NativeWindowsArchitecture',
    'Assert-WindowsPreflight',
    'Test-IsCandidatePathAllowed',
    'Test-CompatiblePython',
    'Get-PythonCandidate',
    'Find-CompatiblePython',
    'Install-PrivatePython',
    'Uninstall-PrivatePython',
    'Test-PayloadManifest',
    'Compare-InstallerVersion',
    'Update-VenvActivationPath',
    'Publish-DiscoveryRegistration',
    'Get-DiscoveryMetadataSnapshot',
    'Restore-DiscoveryRegistration',
    'Remove-DiscoveryRegistration',
    'Remove-OwnedDirectory'
)
