BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\..\scripts\windows\RuntimeInstaller.psm1'
    Import-Module $modulePath -Force
    Initialize-InstallerLog -LogDirectory (Join-Path $TestDrive '日志 目录') | Out-Null
}

Describe 'Candidate selection' {
    It 'rejects aliases Conda and embedded layouts' {
        Test-IsCandidatePathAllowed 'C:\Users\测试 用户\AppData\Local\Microsoft\WindowsApps\python.exe' | Should -BeFalse
        Test-IsCandidatePathAllowed 'C:\Tools\Miniconda\python.exe' | Should -BeFalse
        Test-IsCandidatePathAllowed 'C:\Tools\embedded\python.exe' | Should -BeFalse
    }

    It 'allows a standard CPython path containing spaces and Chinese characters' {
        Test-IsCandidatePathAllowed 'C:\Users\测试 用户\Python313\python.exe' | Should -BeTrue
    }

    It 'enumerates PythonCore PEP 514 tags and prioritizes exact patch metadata' {
        Mock Test-Path { $true } -ModuleName RuntimeInstaller
        Mock Write-InstallerLog { param($Stage, $Message, $Level); throw $Message } -ModuleName RuntimeInstaller
        Mock Get-ChildItem {
            @(
                [PSCustomObject]@{ PSPath = 'HKCU:\Software\Python\PythonCore\3.13' },
                [PSCustomObject]@{ PSPath = 'HKCU:\Software\Python\PythonCore\3.13-e2e' }
            )
        } -ModuleName RuntimeInstaller
        Mock Get-ItemProperty {
            param($LiteralPath)
            if ($LiteralPath -like '*\InstallPath') {
                $executable = if ($LiteralPath -like '*e2e*') { 'C:\Exact\python.exe' } else { 'C:\Fallback\python.exe' }
                return [PSCustomObject]@{ ExecutablePath = $executable }
            }
            $sysVersion = if ($LiteralPath -like '*e2e*') { '3.13.14' } else { '3.13' }
            return [PSCustomObject]@{ SysVersion = $sysVersion }
        } -ModuleName RuntimeInstaller

        $registered = @(InModuleScope RuntimeInstaller {
            Get-RegisteredPythonCandidate -RegistryBase 'HKCU:\Software\Python\PythonCore' -ExpectedVersion '3.13.14'
        })
        Should -Invoke Get-ItemProperty -ModuleName RuntimeInstaller -Times 2 -ParameterFilter { $LiteralPath -like '*e2e*' }
        $registered | Should -HaveCount 2
        $registered[0] | Should -Be 'C:\Exact\python.exe'
    }

    It 'selects only the first candidate that passes the exact health probe' {
        Mock Get-PythonCandidate { @('C:\Python312\python.exe', 'C:\Python313\python.exe') } -ModuleName RuntimeInstaller
        Mock Test-CompatiblePython {
            param($PythonPath, $ExpectedVersion)
            return $PythonPath -like '*Python313*' -and $ExpectedVersion -eq '3.13.14'
        } -ModuleName RuntimeInstaller
        Find-CompatiblePython -ExpectedVersion '3.13.14' | Should -Be 'C:\Python313\python.exe'
    }

    It 'returns no candidate when bundled runtime is forced' {
        Find-CompatiblePython -ExpectedVersion '3.13.14' -ForceBundled | Should -BeNullOrEmpty
    }

    It 'does not misclassify an orphan beneath the managed root as reused' {
        Mock Get-PythonCandidate { @('C:\Managed App\runtime\3.13.14\python.exe') } -ModuleName RuntimeInstaller
        Mock Test-CompatiblePython { $true } -ModuleName RuntimeInstaller
        Find-CompatiblePython -ExpectedVersion '3.13.14' -ManagedRoot 'C:\Managed App' | Should -BeNullOrEmpty
    }

    It 'accepts an exact healthy CPython 3.13.14 x64 probe' {
        Mock Test-Path { $true } -ModuleName RuntimeInstaller
        Mock Invoke-LoggedProcess {
            param($FilePath, $Arguments, $Stage)
            if ($Arguments -contains '-c' -and $FilePath -like '*python.exe') {
                return [PSCustomObject]@{ ExitCode = 0; StdOut = '{"implementation":"cpython","version":"3.13.14","bits":"64bit","ssl":"OpenSSL"}'; StdErr = '' }
            }
            return [PSCustomObject]@{ ExitCode = 0; StdOut = 'healthy'; StdErr = '' }
        } -ModuleName RuntimeInstaller
        Test-CompatiblePython -PythonPath 'C:\Users\测试 用户\Python313\python.exe' -ExpectedVersion '3.13.14' | Should -BeTrue
    }

    It 'rejects inexact versions and wrong architectures' {
        Mock Test-Path { $true } -ModuleName RuntimeInstaller
        Mock Invoke-LoggedProcess {
            [PSCustomObject]@{ ExitCode = 0; StdOut = '{"implementation":"cpython","version":"3.13.13","bits":"32bit","ssl":"OpenSSL"}'; StdErr = '' }
        } -ModuleName RuntimeInstaller
        Test-CompatiblePython -PythonPath 'C:\Python313\python.exe' -ExpectedVersion '3.13.14' | Should -BeFalse
    }

    It 'rejects a candidate when any health process fails' {
        Mock Test-Path { $true } -ModuleName RuntimeInstaller
        Mock Invoke-LoggedProcess { throw 'simulated health failure' } -ModuleName RuntimeInstaller
        Test-CompatiblePython -PythonPath 'C:\Python313\python.exe' -ExpectedVersion '3.13.14' | Should -BeFalse
    }
}

Describe 'Windows Server E2E preflight policy' {
    BeforeEach {
        $script:savedGitHubActions = $env:GITHUB_ACTIONS
        $script:savedRunnerEnvironment = $env:RUNNER_ENVIRONMENT
        $env:GITHUB_ACTIONS = $null
        $env:RUNNER_ENVIRONMENT = $null
        Mock Get-ItemProperty {
            [PSCustomObject]@{ ProductName = 'Microsoft Windows Server 2025 Datacenter' }
        } -ModuleName RuntimeInstaller
        Mock Get-NativeWindowsArchitecture { 'AMD64' } -ModuleName RuntimeInstaller
        Mock Write-InstallerLog {} -ModuleName RuntimeInstaller
    }

    AfterEach {
        $env:GITHUB_ACTIONS = $script:savedGitHubActions
        $env:RUNNER_ENVIRONMENT = $script:savedRunnerEnvironment
    }

    It 'rejects Windows Server by default even on a GitHub-hosted runner' {
        $env:GITHUB_ACTIONS = 'true'
        $env:RUNNER_ENVIRONMENT = 'github-hosted'

        {
            Assert-WindowsPreflight -AppRoot $TestDrive -MinimumFreeBytes 0
        } | Should -Throw '*Windows Server is not a supported target*'
    }

    It 'rejects the explicit override when GITHUB_ACTIONS is missing' {
        $env:RUNNER_ENVIRONMENT = 'github-hosted'

        {
            Assert-WindowsPreflight -AppRoot $TestDrive -MinimumFreeBytes 0 -AllowWindowsServerForE2E
        } | Should -Throw '*requires a GitHub-hosted Actions runner*'
    }

    It 'rejects the explicit override when RUNNER_ENVIRONMENT is missing' {
        $env:GITHUB_ACTIONS = 'true'

        {
            Assert-WindowsPreflight -AppRoot $TestDrive -MinimumFreeBytes 0 -AllowWindowsServerForE2E
        } | Should -Throw '*requires a GitHub-hosted Actions runner*'
    }

    It 'allows the edition override only with both GitHub-hosted markers' {
        $env:GITHUB_ACTIONS = 'true'
        $env:RUNNER_ENVIRONMENT = 'github-hosted'

        {
            Assert-WindowsPreflight -AppRoot $TestDrive -MinimumFreeBytes 0 -AllowWindowsServerForE2E
        } | Should -Not -Throw
    }

    It 'does not bypass the AMD64 architecture check' {
        $env:GITHUB_ACTIONS = 'true'
        $env:RUNNER_ENVIRONMENT = 'github-hosted'
        Mock Get-NativeWindowsArchitecture { 'ARM64' } -ModuleName RuntimeInstaller

        {
            Assert-WindowsPreflight -AppRoot $TestDrive -MinimumFreeBytes 0 -AllowWindowsServerForE2E
        } | Should -Throw '*Unsupported Windows architecture*'
    }

    It 'does not bypass the free-space check' {
        $env:GITHUB_ACTIONS = 'true'
        $env:RUNNER_ENVIRONMENT = 'github-hosted'

        {
            Assert-WindowsPreflight -AppRoot $TestDrive -MinimumFreeBytes ([Int64]::MaxValue) -AllowWindowsServerForE2E
        } | Should -Throw '*Insufficient disk space*'
    }

    It 'rejects the override on a desktop product name' {
        $env:GITHUB_ACTIONS = 'true'
        $env:RUNNER_ENVIRONMENT = 'github-hosted'
        Mock Get-ItemProperty {
            [PSCustomObject]@{ ProductName = 'Windows 11 Pro' }
        } -ModuleName RuntimeInstaller

        {
            Assert-WindowsPreflight -AppRoot $TestDrive -MinimumFreeBytes 0 -AllowWindowsServerForE2E
        } | Should -Throw '*only valid on Windows Server*'
    }
}

Describe 'Lifecycle primitives' {
    It 'encodes quoted and trailing-backslash process arguments for Windows argv parsing' {
        InModuleScope RuntimeInstaller {
            ConvertTo-ProcessArgument -Value 'plain' | Should -Be 'plain'
            ConvertTo-ProcessArgument -Value 'with space' | Should -Be '"with space"'
            ConvertTo-ProcessArgument -Value 'say "hello"' | Should -Be '"say \"hello\""'
            ConvertTo-ProcessArgument -Value 'C:\path with space\' | Should -Be '"C:\path with space\\"'
        }
    }

    It 'falls back to the system environment registry for native architecture' {
        $savedArchitecture = $env:PROCESSOR_ARCHITECTURE
        $savedWowArchitecture = $env:PROCESSOR_ARCHITEW6432
        try {
            $env:PROCESSOR_ARCHITECTURE = $null
            $env:PROCESSOR_ARCHITEW6432 = $null
            Mock Get-ItemProperty {
                [PSCustomObject]@{ PROCESSOR_ARCHITECTURE = 'AMD64' }
            } -ModuleName RuntimeInstaller
            Get-NativeWindowsArchitecture | Should -Be 'AMD64'
        } finally {
            $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
            $env:PROCESSOR_ARCHITEW6432 = $savedWowArchitecture
        }
    }

    It 'compares upgrade and downgrade versions without string ordering' {
        Compare-InstallerVersion -InstalledVersion '0.2.0' -IncomingVersion '0.1.9' | Should -BeGreaterThan 0
        Compare-InstallerVersion -InstalledVersion '0.1.0' -IncomingVersion '0.2.0' | Should -BeLessThan 0
        Compare-InstallerVersion -InstalledVersion '0.1.0' -IncomingVersion '0.1.0' | Should -Be 0
    }

    It 'verifies a payload beneath a Unicode path and detects drift' {
        $payload = Join-Path $TestDrive '负载 空间'
        New-Item -ItemType Directory -Path $payload | Out-Null
        $file = Join-Path $payload '文件.txt'
        [System.IO.File]::WriteAllText($file, 'verified', (New-Object System.Text.UTF8Encoding($false)))
        $stream = [System.IO.File]::OpenRead($file)
        $algorithm = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hash = ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '').ToLowerInvariant()
        } finally {
            $algorithm.Dispose()
            $stream.Dispose()
        }
        $manifest = @{ files = @(@{ path = '文件.txt'; size = (Get-Item $file).Length; sha256 = $hash }) }
        $manifestPath = Join-Path $payload 'payload-manifest.json'
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        (Test-PayloadManifest -PayloadRoot $payload -ManifestPath $manifestPath).files.Count | Should -Be 1
        Set-Content -LiteralPath $file -Value 'tampered' -Encoding UTF8
        { Test-PayloadManifest -PayloadRoot $payload -ManifestPath $manifestPath } | Should -Throw '*mismatch*'
    }

    It 'refuses cleanup outside the application root' {
        $app = Join-Path $TestDrive 'app'
        New-Item -ItemType Directory -Path $app | Out-Null
        { Remove-OwnedDirectory -AppRoot $app -Path $TestDrive } | Should -Throw '*outside*'
    }

    It 'removes the saved private Python installer after uninstall' {
        $app = Join-Path $TestDrive 'private-uninstall'
        $maintenance = Join-Path $app 'maintenance'
        New-Item -ItemType Directory -Path $maintenance | Out-Null
        $savedInstaller = Join-Path $maintenance 'python-installer.exe'
        Set-Content -LiteralPath $savedInstaller -Value 'fixture'
        Mock Invoke-LoggedProcess { 0 } -ModuleName RuntimeInstaller

        Uninstall-PrivatePython -AppRoot $app -InstallerFilename 'python-installer.exe'

        Test-Path -LiteralPath $savedInstaller | Should -BeFalse
        Should -Invoke Invoke-LoggedProcess -ModuleName RuntimeInstaller -Times 1 -Exactly
    }
}

Describe 'Logging retention' {
    It 'formats localized failures as English ASCII diagnostics' {
        $localizedMessage = -join @(
            [char]0x672C,
            [char]0x5730,
            [char]0x5316,
            [char]0x9519,
            [char]0x8BEF,
            [char]0x6587,
            [char]0x672C
        )
        try {
            throw (New-Object System.InvalidOperationException($localizedMessage))
        } catch {
            $diagnostic = Format-InstallerErrorRecord -ErrorRecord $_
        }

        $diagnostic | Should -Match 'ExceptionType=System.InvalidOperationException'
        $diagnostic | Should -Match 'Message=<localized-or-non-ascii-text-omitted>'
        $diagnostic | Should -Not -Match ([regex]::Escape($localizedMessage))
        @($diagnostic.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
    }

    It 'retains safe ASCII failure context and redacts sensitive values' {
        try {
            throw 'Download failed: token=do-not-log-this'
        } catch {
            $diagnostic = Format-InstallerErrorRecord -ErrorRecord $_
        }

        $diagnostic | Should -Match 'Download failed'
        $diagnostic | Should -Match 'token=<redacted>'
        $diagnostic | Should -Not -Match 'do-not-log-this'
    }

    It 'retains at most the newest 20 recognized logs' {
        $logRoot = Join-Path $TestDrive 'retention'
        New-Item -ItemType Directory -Path $logRoot | Out-Null
        1..25 | ForEach-Object {
            $path = Join-Path $logRoot ("installer-test-{0:D2}.log" -f $_)
            Set-Content -LiteralPath $path -Value $_
            (Get-Item $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes($_)
        }
        $currentLog = Initialize-InstallerLog -LogDirectory $logRoot
        Test-Path -LiteralPath $currentLog | Should -BeTrue
        @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log').Count | Should -Be 20
    }
}
