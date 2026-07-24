# Python Runtime Installer

这是一个面向 Windows 10/11 x64 的“一键 Python 环境安装器”项目。最终产物是单个可执行的离线 `.exe`：用户双击后无需管理员权限、无需访问 PyPI，即可获得固定版本的 CPython、受管虚拟环境和完整依赖，并在验证全部通过后才生效。

首版为 `0.1.0`，运行时固定为 CPython `3.13.14` x64。开发和 CI 工具统一由 UV 管理；目标端安装仍使用 `requirements.txt + wheelhouse + pip --no-index`，不要求用户安装 UV。

## 核心行为

- 仅支持 Windows 10/11 x64，不支持 ARM64、32 位 Windows 和 Windows Server。
- 只复用通过完整健康检查的标准 CPython `3.13.14` x64；Store alias、Conda、嵌入式或版本不精确的 Python 一律不动，改装私有运行时。
- 固定安装到 `%LOCALAPPDATA%\Programs\Python Runtime Installer`，不修改用户或系统 `PATH`，不创建桌面快捷方式。
- 在同卷 `.staging` 目录构建，校验 payload、精确安装、功能测试通过后再原子切换；失败时回滚。
- 安装内容不可变。用户自行装入受管 `venv` 的包会在修复或升级时被清除，代码和数据应放在安装目录之外。
- 提供中文简体和英文向导、开始菜单入口、静默安装、英文技术日志、修复/升级/卸载。
- 不捆绑浏览器或 WebDriver；Selenium 与 webdriver-manager 只做导入和元数据验证。

## 项目结构

```text
.github/workflows/             PR/Push CI、Windows 构建发布、每月更新 PR
config/                        产品、运行时、哈希、漏洞例外策略
docs/                          故障排查、安全发布、真实设备验收
installer/                     Inno Setup 工程及生成常量
scripts/build/                 锁定、wheelhouse、SBOM、许可证、签名、发布
scripts/windows/               PowerShell 5.1 安装、事务、检测、卸载
scripts/verify_environment.py  目标环境离线验证器
tests/                         Python 与 Windows PowerShell 合同测试
bootstrap-requirements.*       受管 pip 的独立哈希锁
requirements.in                恰好 14 个获准直接依赖
requirements.txt               Windows CPython 3.13 的完整哈希锁
pyproject.toml / uv.lock       开发与 CI 工具环境
```

## macOS 开发

安装仓库规定的 UV `0.11.29` 后执行：

```bash
uv sync --frozen
uv run ruff format --check .
uv run ruff check .
uv run pytest
uv run python -m scripts.build.validate_config
uv run python -m scripts.build.lock_requirements --check
uv run python -m scripts.build.validate_vulnerability_exceptions
uv run python -m scripts.build.validate_desktop_acceptance
uv run python -m scripts.build.scan_repository
openspec validate --all --strict
```

macOS 负责源码、锁和跨平台测试，不能本地编译或完整验证 Windows EXE。依赖刷新使用：

```bash
uv run python -m scripts.build.lock_requirements --upgrade
uv lock --upgrade
uv sync --frozen
```

必须审阅 `requirements.txt`、`bootstrap-requirements.txt` 和 `uv.lock` 的 diff；不允许手工删除哈希或放宽版本。

## Windows 构建

推荐在 GitHub Actions 手动运行 `Build Windows installer`。它在 `windows-2025` 上执行 CPython 3.13.14、UV、Python/Pester 测试、漏洞审计、官方文件哈希和签名验证、真实 EXE 安装/修复/卸载测试，然后上传完整 artifact。手动运行不会创建 Release；只有与 `config/product.json` 匹配的 `vX.Y.Z` tag 才会发布 GitHub Release，`0.x` 自动标记为 prerelease。

在 Windows Runner 上复现主要构建步骤：

```powershell
$managedPythonKey = 'cpython-3.13.14-windows-x86_64-none'
$temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$managedPythonRoot = Join-Path $temporaryRoot 'python-runtime-installer-build-python'
$env:UV_PYTHON_INSTALL_DIR = $managedPythonRoot
uv python install --no-registry --no-bin $managedPythonKey
$buildPython = @(
    uv --directory $temporaryRoot python find `
        --no-project `
        --managed-python `
        --no-python-downloads `
        --resolve-links `
        $managedPythonKey
) -join ''
uv sync --frozen --python $buildPython
uv run python -m scripts.build.audit_dependencies
Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force
Install-Module PSScriptAnalyzer -RequiredVersion 1.24.0 -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings config/PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path tests/powershell -CI -Output Detailed
.\scripts\build\Prepare-Payload.ps1 -PythonExecutable $buildPython
$compiler = .\scripts\build\Install-InnoSetup.ps1
.\scripts\build\Compile-Installer.ps1 -InnoCompiler $compiler -BuildCommit local
.\scripts\build\Test-Installer.ps1 `
    -InstallerPath .\installer\output\python-runtime-installer-0.1.0-windows-x64-unsigned.exe `
    -ReusablePythonPath $buildPython
.\scripts\build\Finalize-Release.ps1
```

## 用户安装和使用

面向普通用户的逐步说明见 [用户使用指南](docs/user-guide.md)。

交互安装：双击 `.exe`，选择中文或英文并完成向导。启动环境时使用开始菜单中的 “Open Python Environment Terminal”；该入口只为当前终端激活受管 `venv`。

静默安装：

```bat
python-runtime-installer-0.1.0-windows-x64-unsigned.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="C:\Temp\python-runtime-setup.log"
```

返回码为 `0` 才表示 payload、Python、全部依赖和离线功能测试均已通过。自动化部署必须保存进程退出码和 `/LOG` 文件。

再次运行同版本会先验证：健康则保留，漂移或损坏则事务式重建。新版本只允许向前升级；旧版本安装器会拒绝降级且不修改现状。确需降级时，先从开始菜单卸载，再安装旧版。卸载会保留诊断日志，并且绝不删除复用的外部 Python。

## 固定发现位置

- 应用：`%LOCALAPPDATA%\Programs\Python Runtime Installer`
- Python：`%LOCALAPPDATA%\Programs\Python Runtime Installer\venv\Scripts\python.exe`
- manifest：`%LOCALAPPDATA%\Programs\Python Runtime Installer\manifest.json`
- 日志：`%LOCALAPPDATA%\PythonRuntimeInstaller\Logs`
- 注册表：`HKCU\Software\Alune\Python Runtime Installer`

日志只记录阶段、脱敏命令摘要、退出码和错误，不主动记录完整环境变量、token 或证书；最多保留最新 20 份受识别日志，不上传遥测。详见 [故障排查](docs/troubleshooting.md)。

## 中国大陆网络与镜像策略

目标电脑安装时完全离线，因此不需要也不会配置国内 PyPI 镜像。所有 wheel 已在 CI 中从官方 PyPI 获取、按锁文件哈希核验并打进 EXE。这样可以避免用户侧网络慢、镜像同步延迟以及同一安装器内容漂移。

中国大陆用户可能仍会遇到 GitHub Release 下载慢。推荐由组织把完整 Release 成品复制到内部文件服务器、企业网盘或国内对象存储，再使用同一 Release 的 `SHA256SUMS.txt` 校验 EXE；不要拆包、替换 wheel 或重新上传一个未对应原始校验值的文件。项目不自动发布到国内平台，也不把镜像凭据写入仓库。

安全、签名、许可证和发布要求见 [安全与发布](docs/security-release.md)，正式验收见 [Windows 真实设备清单](docs/windows-acceptance-checklist.md)。
