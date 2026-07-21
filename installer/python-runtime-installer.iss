#include "generated-config.iss"

#ifndef BuildCommit
  #define BuildCommit "local"
#endif

#ifdef SignedName
  #define OutputSuffix ""
#else
  #define OutputSuffix "-unsigned"
#endif

[Setup]
AppId={#AppId}
AppName={#ProductName}
AppVersion={#ProductVersion}
AppVerName={#ProductName} {#ProductVersion}
AppPublisher={#Publisher}
AppPublisherURL=https://github.com/alune1212/python-runtime-installer
AppSupportURL=https://github.com/alune1212/python-runtime-installer/issues
AppUpdatesURL=https://github.com/alune1212/python-runtime-installer/releases
VersionInfoVersion={#ProductVersion}
VersionInfoCompany={#Publisher}
VersionInfoDescription=Offline managed CPython environment installer
VersionInfoProductName={#ProductName}
VersionInfoProductVersion={#ProductVersion}
DefaultDirName={localappdata}\Programs\Python Runtime Installer
DefaultGroupName={#ProductName}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.10240
ChangesAssociations=no
ChangesEnvironment=no
CloseApplications=force
RestartApplications=no
AlwaysRestart=no
SetupLogging=yes
Uninstallable=yes
UninstallDisplayName={#ProductName}
CreateUninstallRegKey=yes
LicenseFile=..\LICENSE
OutputDir=output
OutputBaseFilename={#OutputBase}{#OutputSuffix}
Compression=lzma2/ultra64
SolidCompression=yes
DiskSpanning=no
WizardStyle=modern
ShowLanguageDialog=auto

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "chinesesimplified"; MessagesFile: "compiler:Languages\ChineseSimplified.isl"

[CustomMessages]
english.InstallingRuntime=Installing and verifying the managed Python environment...
english.RuntimeInstallFailed=The managed Python environment could not be installed. Review the log in %%LOCALAPPDATA%%\PythonRuntimeInstaller\Logs.
english.UnsupportedArchitecture=Only Windows 10/11 x64 (AMD64) is supported.
english.InsufficientDisk=At least 2 GB of free disk space is required.
english.InstallSuccess=The managed Python environment was installed and verified successfully.
english.HealthySuccess=The existing managed Python environment is healthy; no rebuild was needed.
english.RepairSuccess=Environment drift was found and repaired successfully.
english.UpgradeSuccess=The managed Python environment was upgraded and verified successfully.
english.DowngradeBlocked=A newer version is already installed. Uninstall it before installing this older version.
chinesesimplified.InstallingRuntime=正在安装并验证受管 Python 环境……
chinesesimplified.RuntimeInstallFailed=受管 Python 环境安装失败。请查看 %%LOCALAPPDATA%%\PythonRuntimeInstaller\Logs 中的日志。
chinesesimplified.UnsupportedArchitecture=仅支持 Windows 10/11 x64（AMD64）。
chinesesimplified.InsufficientDisk=安装至少需要 2 GB 可用磁盘空间。
chinesesimplified.InstallSuccess=受管 Python 环境已成功安装并通过验证。
chinesesimplified.HealthySuccess=现有受管 Python 环境健康，无需重建。
chinesesimplified.RepairSuccess=已发现环境漂移并成功完成修复。
chinesesimplified.UpgradeSuccess=受管 Python 环境已成功升级并通过验证。
chinesesimplified.DowngradeBlocked=已安装更高版本。如需安装此旧版本，请先卸载当前版本。

[Files]
Source: "..\build\payload\*"; DestDir: "{tmp}\PythonRuntimePayload"; Flags: ignoreversion recursesubdirs createallsubdirs deleteafterinstall
Source: "..\scripts\windows\RuntimeInstaller.psm1"; DestDir: "{app}\maintenance"; Flags: ignoreversion
Source: "..\scripts\windows\Uninstall-Runtime.ps1"; DestDir: "{app}\maintenance"; Flags: ignoreversion
Source: "..\config\product.json"; DestDir: "{app}\maintenance\config"; Flags: ignoreversion
Source: "..\scripts\windows\Open-Environment.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Open Python Environment Terminal"; Filename: "{app}\Open-Environment.cmd"; WorkingDir: "{userprofile}"
Name: "{group}\Open Installation Logs"; Filename: "{win}\explorer.exe"; Parameters: """{localappdata}\PythonRuntimeInstaller\Logs"""
Name: "{group}\Uninstall Python Runtime Installer"; Filename: "{uninstallexe}"

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\maintenance\Uninstall-Runtime.ps1"" -AppRoot ""{app}"" -ConfigPath ""{app}\maintenance\config\product.json"""; Flags: runhidden waituntilterminated; RunOnceId: "ManagedRuntimeUninstall"

[Code]
const
  PROCESSOR_ARCHITECTURE_AMD64 = 9;
  MinimumFreeBytes = 2147483648;

type
  TSystemInfo = record
    wProcessorArchitecture: Word;
    wReserved: Word;
    dwPageSize: Cardinal;
    lpMinimumApplicationAddress: Cardinal;
    lpMaximumApplicationAddress: Cardinal;
    dwActiveProcessorMask: Cardinal;
    dwNumberOfProcessors: Cardinal;
    dwProcessorType: Cardinal;
    dwAllocationGranularity: Cardinal;
    wProcessorLevel: Word;
    wProcessorRevision: Word;
  end;

var
  ManagedExitCode: Integer;
  CompletionMessage: String;

procedure GetNativeSystemInfo(var SystemInfo: TSystemInfo);
  external 'GetNativeSystemInfo@kernel32.dll stdcall';

function HasCommandLineSwitch(const SwitchName: String): Boolean;
var
  Index: Integer;
begin
  Result := False;
  for Index := 1 to ParamCount do
  begin
    if CompareText(ParamStr(Index), SwitchName) = 0 then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function TryParseSemVer(const Value: String; var Major, Minor, Patch: Integer): Boolean;
var
  FirstDot: Integer;
  SecondDot: Integer;
  Remainder: String;
begin
  Result := False;
  FirstDot := Pos('.', Value);
  if FirstDot = 0 then
    Exit;
  Remainder := Copy(Value, FirstDot + 1, Length(Value));
  SecondDot := Pos('.', Remainder);
  if SecondDot = 0 then
    Exit;
  Major := StrToIntDef(Copy(Value, 1, FirstDot - 1), -1);
  Minor := StrToIntDef(Copy(Remainder, 1, SecondDot - 1), -1);
  Patch := StrToIntDef(Copy(Remainder, SecondDot + 1, Length(Remainder)), -1);
  Result := (Major >= 0) and (Minor >= 0) and (Patch >= 0);
end;

function CompareSemVer(const Left, Right: String): Integer;
var
  LeftMajor, LeftMinor, LeftPatch: Integer;
  RightMajor, RightMinor, RightPatch: Integer;
begin
  if not TryParseSemVer(Left, LeftMajor, LeftMinor, LeftPatch) or
     not TryParseSemVer(Right, RightMajor, RightMinor, RightPatch) then
  begin
    Result := 1;
    Exit;
  end;
  Result := LeftMajor - RightMajor;
  if Result = 0 then
    Result := LeftMinor - RightMinor;
  if Result = 0 then
    Result := LeftPatch - RightPatch;
end;

function InitializeSetup(): Boolean;
var
  SystemInfo: TSystemInfo;
  ProductName: String;
  InstalledVersion: String;
begin
  GetNativeSystemInfo(SystemInfo);
  Result := SystemInfo.wProcessorArchitecture = PROCESSOR_ARCHITECTURE_AMD64;
  if not Result and not WizardSilent then
    MsgBox(CustomMessage('UnsupportedArchitecture'), mbError, MB_OK);
  if Result and RegQueryStringValue(
    HKLM,
    'SOFTWARE\Microsoft\Windows NT\CurrentVersion',
    'ProductName',
    ProductName
  ) and (Pos('Server', ProductName) > 0) then
  begin
    Result := False;
    if not WizardSilent then
      MsgBox(CustomMessage('UnsupportedArchitecture'), mbError, MB_OK);
  end;
  if Result and RegQueryStringValue(
    HKCU,
    '{#RegistryPath}',
    'InstallerVersion',
    InstalledVersion
  ) and (CompareSemVer(InstalledVersion, '{#ProductVersion}') > 0) then
  begin
    ManagedExitCode := 21;
    Result := False;
    if not WizardSilent then
      MsgBox(CustomMessage('DowngradeBlocked'), mbError, MB_OK);
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  FreeBytes: Int64;
  TotalBytes: Int64;
begin
  Result := '';
  NeedsRestart := False;
  if not GetSpaceOnDisk64(ExpandConstant('{localappdata}'), FreeBytes, TotalBytes) then
  begin
    Result := CustomMessage('InsufficientDisk');
    Exit;
  end;
  if FreeBytes < MinimumFreeBytes then
    Result := CustomMessage('InsufficientDisk');
end;

function GetCustomSetupExitCode(): Integer;
begin
  Result := ManagedExitCode;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpFinished) and (CompletionMessage <> '') then
    WizardForm.FinishedLabel.Caption := CompletionMessage;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Parameters: String;
  ResultCode: Integer;
  StatusPath: String;
  StatusValue: AnsiString;
begin
  if CurStep <> ssPostInstall then
    Exit;

  WizardForm.StatusLabel.Caption := CustomMessage('InstallingRuntime');
  ResultCode := 20;
  StatusPath := ExpandConstant('{tmp}\PythonRuntimeInstaller.status');
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-File "' + ExpandConstant('{tmp}\PythonRuntimePayload\scripts\windows\Install-Runtime.ps1') + '" ' +
    '-AppRoot "' + ExpandConstant('{app}') + '" ' +
    '-PayloadRoot "' + ExpandConstant('{tmp}\PythonRuntimePayload') + '" ' +
    '-ConfigPath "' + ExpandConstant('{tmp}\PythonRuntimePayload\config\product.json') + '" ' +
    '-RequirementsPath "' + ExpandConstant('{tmp}\PythonRuntimePayload\requirements.txt') + '" ' +
    '-BuildCommit "{#BuildCommit}" ' +
    '-StatusPath "' + StatusPath + '"';
  if HasCommandLineSwitch('/FORCEBUNDLED') then
    Parameters := Parameters + ' -ForceBundled';

  if not Exec(
    ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters,
    '',
    SW_HIDE,
    ewWaitUntilTerminated,
    ResultCode
  ) or (ResultCode <> 0) then
  begin
    ManagedExitCode := ResultCode;
    Log(Format('Managed runtime installation failed with exit code %d.', [ResultCode]));
    if ResultCode = 21 then
      RaiseException(CustomMessage('DowngradeBlocked'))
    else
      RaiseException(CustomMessage('RuntimeInstallFailed'));
  end;
  if LoadStringFromFile(StatusPath, StatusValue) then
  begin
    if StatusValue = 'healthy' then
      CompletionMessage := CustomMessage('HealthySuccess')
    else if StatusValue = 'repair' then
      CompletionMessage := CustomMessage('RepairSuccess')
    else if StatusValue = 'upgrade' then
      CompletionMessage := CustomMessage('UpgradeSuccess')
    else
      CompletionMessage := CustomMessage('InstallSuccess');
  end
  else
    CompletionMessage := CustomMessage('InstallSuccess');
end;
