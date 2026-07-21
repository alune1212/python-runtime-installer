# 安全、签名与发布

## 发布门禁

Windows 完整构建必须依次通过：配置/标签一致性、UV 冻结同步、格式与静态检查、Python/Pester 测试、PowerShell 5.1 分析、锁一致性、漏洞例外有效期、依赖审计、CPython 与 Inno Setup 哈希/发布者验证、固定提交的简体中文翻译及许可证哈希验证、二进制 wheel-only 构建、许可证与源码证据、CycloneDX SBOM、真实 EXE 安装/修复/卸载测试、secret scan 和 release evidence 一致性。

手动 dispatch 只上传 Actions artifact。只有 `vX.Y.Z` tag 与 `config/product.json` 一致且全部门禁成功时才创建 GitHub Release；`0.1.0` 属于 prerelease。普通 push、PR 和月度刷新绝不发布、打 tag 或自动合并。

## 可选 Authenticode 签名

仓库可配置以下 Actions secrets：

- `WINDOWS_SIGNING_CERTIFICATE_BASE64`：PFX 文件的 Base64 内容；
- `WINDOWS_SIGNING_CERTIFICATE_PASSWORD`：PFX 密码；
- `WINDOWS_SIGNING_TIMESTAMP_URL`：可选 RFC 3161 时间戳地址，未设时使用 DigiCert 默认地址。

证书只在临时 Windows Runner 上解码，使用 Windows SDK `signtool` 签名和验证，并在 `finally` 中删除。两个必需 secret 任一缺失时仍可构建，但文件名带 `-unsigned`，同时输出 `UNSIGNED_BUILD.md`。配置签名时 Release 中不会同时发布 unsigned EXE。

## 漏洞例外

默认任何已知漏洞都会阻断构建。确需临时接受时，只能修改 `config/vulnerability-exceptions.json`，每条必须含漏洞 `id`、充分的 `reason`、责任 `owner` 和 ISO 日期 `expires`。结构错误、重复 ID 或已过期条目按无例外处理。例外必须有期限，并通过代码审查；不得在工作流里跳过 audit。

## 发布证据和校验

Release 顶层提供 EXE、`SHA256SUMS.txt`、CycloneDX JSON SBOM、第三方 notices、build provenance、payload manifest 和 evidence ZIP。ZIP 内含项目、Python、依赖、Inno Setup 及简体中文翻译的许可证材料，翻译原始 `.isl`、配置要求的依赖源码证据、SBOM 与 provenance。

PowerShell 校验示例：

```powershell
(Get-FileHash .\python-runtime-installer-0.1.0-windows-x64.exe -Algorithm SHA256).Hash.ToLowerInvariant()
Get-AuthenticodeSignature .\python-runtime-installer-0.1.0-windows-x64.exe | Format-List
```

计算值必须与 `SHA256SUMS.txt` 相同。签名版还必须是 `Valid`，并由预期企业证书签发。

## 第三方再分发

复制安装器时必须同时保留校验和及 evidence。依赖许可证义务来自精确 wheel 集合；Inno Setup 与固定提交的简体中文翻译分别保留许可证，翻译源文件也随 evidence 提供；MySQL Connector/Python 等配置项还会保留官方 sdist 与其 PyPI SHA-256 作为源码证据。再分发方仍需自行确认其使用和分发方式符合各许可证，不得删除 notice、许可证或应提供的源码材料。

## GitHub 权限

- CI：`contents: read`。
- tag 发布 job：仅该 job 使用 `contents: write`。
- 月度刷新：`contents: write` 与 `pull-requests: write`，仓库 Actions 设置必须允许 GitHub Actions 创建 PR。

月度 workflow 只在所有门禁通过且锁文件确有变化时创建或更新 `automation/monthly-dependency-refresh` PR；不自动 merge、tag 或 Release。wheel 不兼容、漏洞、许可证或功能验证失败会直接留在 workflow 日志供维护者处理。
