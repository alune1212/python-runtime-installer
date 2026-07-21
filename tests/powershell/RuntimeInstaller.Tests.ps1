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

Describe 'Lifecycle primitives' {
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
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
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
}

Describe 'Logging retention' {
    It 'retains at most the newest 20 recognized logs' {
        $logRoot = Join-Path $TestDrive 'retention'
        New-Item -ItemType Directory -Path $logRoot | Out-Null
        1..25 | ForEach-Object {
            $path = Join-Path $logRoot ("installer-test-{0:D2}.log" -f $_)
            Set-Content -LiteralPath $path -Value $_
            (Get-Item $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes($_)
        }
        Initialize-InstallerLog -LogDirectory $logRoot | Out-Null
        @(Get-ChildItem -LiteralPath $logRoot -Filter 'installer-*.log').Count | Should -Be 20
    }
}
