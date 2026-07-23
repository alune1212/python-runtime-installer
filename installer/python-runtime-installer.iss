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
english.RuntimeInstallFailed=The managed Python environment could not be installed. Review the log in %1.
english.InstallFailedHeading=Installation failed
english.UnsupportedArchitecture=Only Windows 10/11 x64 (AMD64) is supported.
english.InsufficientDisk=At least 2 GB of free disk space is required.
english.InstallSuccess=The managed Python environment was installed and verified successfully.
english.HealthySuccess=The existing managed Python environment is healthy; no rebuild was needed.
english.RepairSuccess=Environment drift was found and repaired successfully.
english.UpgradeSuccess=The managed Python environment was upgraded and verified successfully.
english.DowngradeBlocked=A newer version is already installed. Uninstall it before installing this older version.
chinesesimplified.InstallingRuntime=正在安装并验证受管 Python 环境……
chinesesimplified.RuntimeInstallFailed=受管 Python 环境安装失败。请查看 %1 中的日志。
chinesesimplified.InstallFailedHeading=安装失败
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
Name: "{group}\Open Python Environment Terminal"; Filename: "{app}\Open-Environment.cmd"; WorkingDir: "{%USERPROFILE|{userdocs}}"
Name: "{group}\Open Installation Logs"; Filename: "{win}\explorer.exe"; Parameters: """{localappdata}\PythonRuntimeInstaller\Logs"""
Name: "{group}\Uninstall Python Runtime Installer"; Filename: "{uninstallexe}"

[Run]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "{code:GetManagedRuntimeParameters}"; Flags: runhidden waituntilterminated; BeforeInstall: BeginManagedRuntimeInstall; AfterInstall: CompleteManagedRuntimeInstall

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
  ExistingManagedManifest: Boolean;
  ManagedInstallStarted: Boolean;
  ManagedStatusPath: String;

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

function IsGitHubHostedServerE2EAllowed(): Boolean;
begin
  Result :=
    HasCommandLineSwitch('/E2EALLOWWINDOWSSERVER') and
    (CompareText(GetEnv('GITHUB_ACTIONS'), 'true') = 0) and
    (CompareText(GetEnv('RUNNER_ENVIRONMENT'), 'github-hosted') = 0);
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
  if Result and HasCommandLineSwitch('/E2EALLOWWINDOWSSERVER') and
     not IsGitHubHostedServerE2EAllowed() then
  begin
    Result := False;
    Log('Rejected unauthorized test-only Windows Server E2E override.');
    if not WizardSilent then
      MsgBox(CustomMessage('UnsupportedArchitecture'), mbError, MB_OK);
  end;
  if Result and RegQueryStringValue(
    HKLM,
    'SOFTWARE\Microsoft\Windows NT\CurrentVersion',
    'ProductName',
    ProductName
  ) and (Pos('Server', ProductName) > 0) then
  begin
    if IsGitHubHostedServerE2EAllowed() then
      Log('Accepted test-only Windows Server preflight override for GitHub-hosted E2E.')
    else
    begin
      Result := False;
      if not WizardSilent then
        MsgBox(CustomMessage('UnsupportedArchitecture'), mbError, MB_OK);
    end;
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
  ExistingManagedManifest := FileExists(ExpandConstant('{app}\manifest.json'));
  ManagedStatusPath := ExpandConstant('{tmp}\PythonRuntimeInstaller.status');
  DeleteFile(ManagedStatusPath);
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
  begin
    WizardForm.FinishedLabel.Caption := CompletionMessage;
    if ManagedExitCode <> 0 then
      WizardForm.FinishedHeadingLabel.Caption := CustomMessage('InstallFailedHeading');
  end;
end;

function GetManagedRuntimeParameters(Param: String): String;
var
  Parameters: String;
begin
  Parameters := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass ' +
    '-File "' + ExpandConstant('{tmp}\PythonRuntimePayload\scripts\windows\Install-Runtime.ps1') + '" ' +
    '-AppRoot "' + ExpandConstant('{app}') + '" ' +
    '-PayloadRoot "' + ExpandConstant('{tmp}\PythonRuntimePayload') + '" ' +
    '-ConfigPath "' + ExpandConstant('{tmp}\PythonRuntimePayload\config\product.json') + '" ' +
    '-RequirementsPath "' + ExpandConstant('{tmp}\PythonRuntimePayload\requirements.txt') + '" ' +
    '-BuildCommit "{#BuildCommit}" ' +
    '-StatusPath "' + ManagedStatusPath + '"';
  if HasCommandLineSwitch('/FORCEBUNDLED') then
    Parameters := Parameters + ' -ForceBundled';
  if IsGitHubHostedServerE2EAllowed() then
    Parameters := Parameters + ' -AllowWindowsServerForE2E';
  if HasCommandLineSwitch('/E2EFAILAFTERSTAGING') then
    Parameters := Parameters + ' -TestFailAfterStagingVerification';
  Result := Parameters;
end;

procedure BeginManagedRuntimeInstall;
begin
  ManagedInstallStarted := True;
  WizardForm.StatusLabel.Caption := CustomMessage('InstallingRuntime');
  DeleteFile(ManagedStatusPath);
end;

procedure ReportManagedRuntimeFailure(ErrorMessage: String; ExitCode: Integer);
begin
  ManagedExitCode := ExitCode;
  CompletionMessage := ErrorMessage;
  SuppressibleMsgBox(ErrorMessage, mbCriticalError, MB_OK, IDOK);
end;

procedure CompleteManagedRuntimeInstall;
var
  StatusValue: AnsiString;
  ErrorMessage: String;
begin
  if not LoadStringFromFile(ManagedStatusPath, StatusValue) then
  begin
    Log('Managed runtime installation did not write a completion status.');
    ErrorMessage := FmtMessage(CustomMessage('RuntimeInstallFailed'), [ExpandConstant('{localappdata}\PythonRuntimeInstaller\Logs')]);
    ReportManagedRuntimeFailure(ErrorMessage, 20);
    Exit;
  end;
  if StatusValue = 'downgrade-blocked' then
  begin
    ReportManagedRuntimeFailure(CustomMessage('DowngradeBlocked'), 21);
  end
  else if StatusValue = 'failed' then
  begin
    Log('Managed runtime installation reported failure.');
    ErrorMessage := FmtMessage(CustomMessage('RuntimeInstallFailed'), [ExpandConstant('{localappdata}\PythonRuntimeInstaller\Logs')]);
    ReportManagedRuntimeFailure(ErrorMessage, 20);
  end
  else if StatusValue = 'healthy' then
    CompletionMessage := CustomMessage('HealthySuccess')
  else if StatusValue = 'repair' then
    CompletionMessage := CustomMessage('RepairSuccess')
  else if StatusValue = 'upgrade' then
    CompletionMessage := CustomMessage('UpgradeSuccess')
  else if StatusValue = 'install' then
    CompletionMessage := CustomMessage('InstallSuccess')
  else
  begin
    Log('Managed runtime installation wrote an unexpected completion status.');
    ErrorMessage := FmtMessage(CustomMessage('RuntimeInstallFailed'), [ExpandConstant('{localappdata}\PythonRuntimeInstaller\Logs')]);
    ReportManagedRuntimeFailure(ErrorMessage, 20);
  end;
end;

procedure RemoveFailedCleanInstallRegistration;
var
  Index: Integer;
  SubkeyNames: TArrayOfString;
  UninstallRoot: String;
  SubkeyPath: String;
  InstallLocation: String;
  DisplayName: String;
  ApplicationRoot: String;
begin
  UninstallRoot := 'Software\Microsoft\Windows\CurrentVersion\Uninstall';
  ApplicationRoot := RemoveBackslashUnlessRoot(ExpandConstant('{app}'));
  if not RegGetSubkeyNames(HKCU, UninstallRoot, SubkeyNames) then
    Exit;

  for Index := 0 to GetArrayLength(SubkeyNames) - 1 do
  begin
    SubkeyPath := UninstallRoot + '\' + SubkeyNames[Index];
    if RegQueryStringValue(HKCU, SubkeyPath, 'InstallLocation', InstallLocation) and
       RegQueryStringValue(HKCU, SubkeyPath, 'DisplayName', DisplayName) and
       (CompareText(RemoveBackslashUnlessRoot(InstallLocation), ApplicationRoot) = 0) and
       (CompareText(DisplayName, '{#ProductName}') = 0) then
    begin
      if RegDeleteKeyIncludingSubkeys(HKCU, SubkeyPath) then
        Log('Removed failed clean-install uninstall registration: ' + SubkeyPath)
      else
        Log('Could not remove failed clean-install uninstall registration: ' + SubkeyPath);
    end;
  end;
end;

procedure DeinitializeSetup;
begin
  if ManagedInstallStarted and (ManagedExitCode <> 0) and
     not ExistingManagedManifest then
  begin
    Log('Cleaning shell state from failed clean installation.');
    RegDeleteKeyIncludingSubkeys(HKCU, '{#RegistryPath}');
    RemoveFailedCleanInstallRegistration;
    if not DelTree(ExpandConstant('{group}'), True, True, True) then
      Log('Could not completely remove the failed clean-install Start menu group.');
    if not DelTree(ExpandConstant('{app}'), True, True, True) then
      Log('Could not completely remove the failed clean-install application directory.');
  end;
end;
