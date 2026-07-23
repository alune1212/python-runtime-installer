# 故障排查

## 先收集什么

1. 保留安装器 `/LOG=` 指定的 Inno Setup 日志。
2. 打开 `%LOCALAPPDATA%\PythonRuntimeInstaller\Logs`，收集对应时间的英文 `installer-*.log`。
3. 记录 Windows 版本、CPU 架构、安装器文件名和 `SHA256SUMS.txt` 校验结果。
4. 不要在工单中提交密码、token、PFX、完整环境变量或业务数据；如错误输出意外包含敏感值，先人工遮盖。

日志在失败和卸载后保留，最多保存最新 20 份受识别安装日志。安装器没有遥测或自动上传功能。

## 常见问题

### 不支持的平台或空间不足

仅支持 Windows 10/11 x64 桌面系统，开始写入前要求目标盘至少 2 GiB 可用空间。ARM64、32 位、Windows Server 或空间不足会在变更受管环境前退出。

### 已有 Python 为什么没有复用

复用条件是标准 CPython `3.13.14` x64，并且执行、实现标识、SSL、标准库、`ensurepip`、`venv` 和临时虚拟环境全部健康。Microsoft Store alias、Conda、嵌入式发行版、错误补丁版本和失败候选会被原样保留；安装器会使用自己的私有 Python。

### 重装后自定义包消失

这是预期行为。受管环境不可变，同版本修复和向前升级会用锁定集合整体替换环境。不要把自定义包、代码或数据放入安装目录；需要额外依赖时请为业务项目单独创建环境。

### Selenium 找不到浏览器或驱动

首版只安装 Selenium 和 webdriver-manager Python 包，不安装 Chrome、Edge、Firefox 或 WebDriver，也不会在验证时联网下载。浏览器和驱动由业务应用另行管理。

### 安装器拒绝降级

直接降级会返回失败且不修改现有环境。先通过开始菜单卸载当前版本，再安装已保存且校验通过的旧版。

### SmartScreen 警告

文件名含 `-unsigned` 表示没有 Authenticode 证书，SmartScreen 可能提示风险。先从可信分发点取得文件并对照 `SHA256SUMS.txt`；企业生产分发应使用已签名构建。

### 中国大陆下载较慢

这只影响取得完整 EXE，不影响安装。可将完整 Release 镜像到内部或国内存储，并核对 GitHub Release 公布的 SHA-256。不要为目标端设置临时 PyPI 镜像，安装器不会访问索引。
