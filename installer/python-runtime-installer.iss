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
english.ProgressPreflight=Checking system compatibility...
english.ProgressIntegrity=Verifying offline payload integrity...
english.ProgressRepairCheck=Checking the existing managed environment...
english.ProgressPythonDiscovery=Selecting a compatible Python runtime...
english.ProgressPythonInstall=Installing private CPython 3.13.14...
english.ProgressVenv=Creating the isolated Python environment...
english.ProgressBootstrap=Preparing locked installer tooling...
english.ProgressDependencies=Installing locked offline dependencies...
english.ProgressVerification=Verifying the staged environment...
english.ProgressActivation=Activating the verified environment...
english.ProgressEntrypoints=Rebuilding command launchers...
english.ProgressFinal=Running final environment verification...
english.ProgressCleanup=Cleaning up replaced installation files...
english.ProgressFailed=Installation failed; retained diagnostics are available.
english.ProgressComplete=Finishing installation...
english.ProgressElapsed=%1 Elapsed: %2 seconds.
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
chinesesimplified.ProgressPreflight=正在检查系统兼容性……
chinesesimplified.ProgressIntegrity=正在验证离线负载完整性……
chinesesimplified.ProgressRepairCheck=正在检查现有受管环境……
chinesesimplified.ProgressPythonDiscovery=正在选择兼容的 Python 运行时……
chinesesimplified.ProgressPythonInstall=正在安装私有 CPython 3.13.14……
chinesesimplified.ProgressVenv=正在创建隔离的 Python 环境……
chinesesimplified.ProgressBootstrap=正在准备锁定的安装工具……
chinesesimplified.ProgressDependencies=正在安装锁定的离线依赖……
chinesesimplified.ProgressVerification=正在验证 staging 环境……
chinesesimplified.ProgressActivation=正在激活已验证的环境……
chinesesimplified.ProgressEntrypoints=正在重建命令启动器……
chinesesimplified.ProgressFinal=正在执行最终环境验证……
chinesesimplified.ProgressCleanup=正在清理已替换的安装文件……
chinesesimplified.ProgressFailed=安装失败，诊断日志已保留。
chinesesimplified.ProgressComplete=正在完成安装……
chinesesimplified.ProgressElapsed=%1 已用 %2 秒。

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
Filename: "{cmd}"; Parameters: "/d /c exit /b 0"; Flags: runhidden waituntilterminated; BeforeInstall: RunManagedRuntimeInstall; AfterInstall: CompleteManagedRuntimeInstall

[UninstallRun]
Filename: "{sys}\WindowsPowerShell\v1.0\powershell.exe"; Parameters: "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ""{app}\maintenance\Uninstall-Runtime.ps1"" -AppRoot ""{app}"" -ConfigPath ""{app}\maintenance\config\product.json"""; Flags: runhidden waituntilterminated; RunOnceId: "ManagedRuntimeUninstall"

[Code]
const
  PROCESSOR_ARCHITECTURE_AMD64 = 9;
  MinimumFreeBytes = 2147483648;
  ManagedProgressPrefix = 'PYRUNTIME_PROGRESS|';
  ManagedHeartbeatPrefix = 'PYRUNTIME_HEARTBEAT|';

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
  ManagedProgressBase: Integer;

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

function GetManagedRuntimeParameters: String;
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

function GetManagedProgressMessage(const Stage: String): String;
begin
  if Stage = 'preflight' then
    Result := CustomMessage('ProgressPreflight')
  else if Stage = 'integrity' then
    Result := CustomMessage('ProgressIntegrity')
  else if Stage = 'repair-check' then
    Result := CustomMessage('ProgressRepairCheck')
  else if Stage = 'python-discovery' then
    Result := CustomMessage('ProgressPythonDiscovery')
  else if Stage = 'python-install' then
    Result := CustomMessage('ProgressPythonInstall')
  else if Stage = 'venv-create' then
    Result := CustomMessage('ProgressVenv')
  else if Stage = 'bootstrap-install' then
    Result := CustomMessage('ProgressBootstrap')
  else if Stage = 'dependency-install' then
    Result := CustomMessage('ProgressDependencies')
  else if Stage = 'verification' then
    Result := CustomMessage('ProgressVerification')
  else if Stage = 'activation' then
    Result := CustomMessage('ProgressActivation')
  else if Stage = 'entrypoint-relink' then
    Result := CustomMessage('ProgressEntrypoints')
  else if Stage = 'verification-final' then
    Result := CustomMessage('ProgressFinal')
  else if (Stage = 'cleanup') or (Stage = 'python-uninstall') then
    Result := CustomMessage('ProgressCleanup')
  else if Stage = 'failed' then
    Result := CustomMessage('ProgressFailed')
  else if Stage = 'complete' then
    Result := CustomMessage('ProgressComplete')
  else
    Result := CustomMessage('InstallingRuntime');
end;

function GetManagedProgressPosition(const Stage: String): Integer;
begin
  if Stage = 'preflight' then
    Result := 5
  else if Stage = 'integrity' then
    Result := 10
  else if Stage = 'repair-check' then
    Result := 12
  else if Stage = 'python-discovery' then
    Result := 15
  else if Stage = 'python-install' then
    Result := 20
  else if Stage = 'venv-create' then
    Result := 30
  else if Stage = 'bootstrap-install' then
    Result := 35
  else if Stage = 'dependency-install' then
    Result := 40
  else if Stage = 'verification' then
    Result := 65
  else if Stage = 'activation' then
    Result := 75
  else if Stage = 'entrypoint-relink' then
    Result := 82
  else if Stage = 'verification-final' then
    Result := 92
  else if (Stage = 'cleanup') or (Stage = 'python-uninstall') then
    Result := 96
  else if Stage = 'failed' then
    Result := 99
  else if Stage = 'complete' then
    Result := 100
  else
    Result := 1;
end;

procedure SetManagedProgress(const Stage: String);
begin
  ManagedProgressBase := GetManagedProgressPosition(Stage);
  WizardForm.StatusLabel.Caption := GetManagedProgressMessage(Stage);
  WizardForm.ProgressGauge.Style := npbstNormal;
  WizardForm.ProgressGauge.Min := 0;
  WizardForm.ProgressGauge.Max := 100;
  WizardForm.ProgressGauge.Position := ManagedProgressBase;
  WizardForm.StatusLabel.Update;
  WizardForm.ProgressGauge.Update;
end;

procedure HandleManagedRuntimeOutput(
  const S: String;
  const Error, FirstLine: Boolean
);
var
  Payload: String;
  Stage: String;
  ElapsedText: String;
  Separator: Integer;
  ElapsedSeconds: Integer;
  Position: Integer;
begin
  if Error then
  begin
    Log('Managed runtime output error: ' + S);
    Exit;
  end;
  if Pos(ManagedProgressPrefix, S) = 1 then
  begin
    Stage := Copy(S, Length(ManagedProgressPrefix) + 1, Length(S));
    SetManagedProgress(Stage);
    Log('Managed runtime progress: ' + Stage);
    Exit;
  end;
  if Pos(ManagedHeartbeatPrefix, S) = 1 then
  begin
    Payload := Copy(S, Length(ManagedHeartbeatPrefix) + 1, Length(S));
    Separator := Pos('|', Payload);
    if Separator = 0 then
      Exit;
    Stage := Copy(Payload, 1, Separator - 1);
    ElapsedText := Copy(Payload, Separator + 1, Length(Payload));
    ElapsedSeconds := StrToIntDef(ElapsedText, 0);
    ManagedProgressBase := GetManagedProgressPosition(Stage);
    WizardForm.StatusLabel.Caption := FmtMessage(CustomMessage('ProgressElapsed'), [GetManagedProgressMessage(Stage), ElapsedText]);
    Position := ManagedProgressBase + (ElapsedSeconds div 5);
    if Position > ManagedProgressBase + 3 then
      Position := ManagedProgressBase + 3;
    if Position > 98 then
      Position := 98;
    WizardForm.ProgressGauge.Position := Position;
    WizardForm.StatusLabel.Update;
    WizardForm.ProgressGauge.Update;
    Exit;
  end;
  if S <> '' then
    Log('Managed runtime output: ' + S);
end;

procedure RunManagedRuntimeInstall;
var
  ResultCode: Integer;
begin
  ManagedInstallStarted := True;
  SetManagedProgress('preflight');
  DeleteFile(ManagedStatusPath);
  try
    if not ExecAndLogOutput(
      ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
      GetManagedRuntimeParameters,
      '',
      SW_SHOWNORMAL,
      ewWaitUntilTerminated,
      ResultCode,
      @HandleManagedRuntimeOutput
    ) then
    begin
      Log('Could not start the managed runtime process.');
      SaveStringToFile(ManagedStatusPath, 'failed', False);
    end
    else
      Log(Format('Managed runtime process exit code: %d', [ResultCode]));
  except
    Log('Managed runtime process exception: ' + GetExceptionMessage);
    SaveStringToFile(ManagedStatusPath, 'failed', False);
  end;
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
