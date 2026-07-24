# Python Runtime Installer 用户使用指南

适用于 Windows 10/11 64 位电脑。安装不需要管理员权限，也不需要联网。

## 1. 安装

将下面两个文件放在同一文件夹：

- `python-runtime-installer-0.1.0-windows-x64-unsigned.exe`
- `SHA256SUMS.txt`

在该文件夹打开 PowerShell，核对文件：

```powershell
Get-FileHash .\python-runtime-installer-0.1.0-windows-x64-unsigned.exe -Algorithm SHA256
Get-Content .\SHA256SUMS.txt
```

两个 SHA-256 必须完全相同。然后双击 EXE，选择语言并等待安装成功。

文件未签名。如果 Windows 显示 SmartScreen，只能在文件来自可信来源且 SHA-256
完全一致时，选择“更多信息”→“仍要运行”。

## 2. 打开 Python 环境

按 Windows 键，搜索并打开：

```text
Open Python Environment Terminal
```

打开后执行：

```bat
python --version
where python
python -m pip check
```

正常结果应包含 Python `3.13.14`，并显示 `No broken requirements found.`。

如果没有找到开始菜单入口，在 PowerShell 中执行：

```powershell
$launcher = Join-Path $env:LOCALAPPDATA 'Programs\Python Runtime Installer\Open-Environment.cmd'
Start-Process -FilePath $launcher
```

## 3. 使用 Python

进入交互模式：

```bat
python
```

输入：

```python
print("Hello, Python!")
```

退出：

```python
exit()
```

运行自己的 Python 文件：

```bat
python "%USERPROFILE%\Documents\hello.py"
```

文件路径包含空格时必须保留双引号。

## 4. 不打开专用终端直接运行

在 PowerShell 中执行：

```powershell
$python = Join-Path $env:LOCALAPPDATA 'Programs\Python Runtime Installer\venv\Scripts\python.exe'
& $python --version
& $python 'C:\路径\你的脚本.py'
```

## 5. 查看已安装的软件包

```bat
python -m pip list
python -m pip check
```

不要在该环境中执行 `pip install`。修复或升级时，额外安装的软件包会被清除。
自己的脚本和数据应保存在“文档”等安装目录之外的位置。

## 6. 修复、日志和卸载

环境损坏时，重新运行同一个安装 EXE，安装器会自动检查并修复。

打开日志目录：

```powershell
explorer.exe (Join-Path $env:LOCALAPPDATA 'PythonRuntimeInstaller\Logs')
```

卸载时，在开始菜单搜索：

```text
Uninstall Python Runtime Installer
```

也可以进入 Windows“设置”→“应用”→“已安装的应用”进行卸载。卸载后诊断日志会保留。