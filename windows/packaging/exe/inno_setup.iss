; Rendered by setup.dart from make_config.yaml: every {{NAME}} is filled there.
[Setup]
AppId={{APP_ID}}
AppVersion={{APP_VERSION}}
AppName={{DISPLAY_NAME}}
AppPublisher={{PUBLISHER_NAME}}
AppPublisherURL={{PUBLISHER_URL}}
AppSupportURL={{PUBLISHER_URL}}
AppUpdatesURL={{PUBLISHER_URL}}
DefaultDirName={{INSTALL_DIR_NAME}}
DisableProgramGroupPage=yes
OutputDir={{OUTPUT_DIR}}
OutputBaseFilename={{OUTPUT_BASE_FILENAME}}
Compression=lzma
SolidCompression=yes
SetupIconFile={{SETUP_ICON_FILE}}
WizardStyle=modern
PrivilegesRequired={{PRIVILEGES_REQUIRED}}
ArchitecturesAllowed={{ARCH}}
ArchitecturesInstallIn64BitMode={{ARCH}}
UninstallDisplayIcon={app}\{{EXECUTABLE_NAME}}
ChangesAssociations=yes
UsePreviousAppDir=yes
UsePreviousGroup=yes
UsePreviousTasks=yes

[Code]
const
  SHCNE_ASSOCCHANGED = $08000000;
  SHCNF_IDLIST = $0000;
  HelperService = '{{HELPER_SERVICE}}';

var
  IsUpgrade: Boolean;
  PreviousVersion: String;
  HelperHeld: Boolean;

procedure SHChangeNotify(wEventId: Integer; uFlags: Integer; dwItem1: Integer; dwItem2: Integer); external 'SHChangeNotify@shell32.dll stdcall';

function RunHidden(const Filename, Params: String): Integer;
var
  ResultCode: Integer;
begin
  ResultCode := -1;
  Exec(Filename, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Result := ResultCode;
end;

procedure KillProcess(const Name: String);
begin
  RunHidden('taskkill.exe', '/f /t /im ' + Name);
end;

// The stable app and a pre-release run Cores of the same name, so only the
// one started from this install goes.
procedure KillCore;
var
  Dir: String;
begin
  Dir := AddBackslash(ExpandConstant('{app}'));
  StringChangeEx(Dir, '''', '''''', True);
  RunHidden('powershell.exe', '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Get-Process -Name FlClashCore -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith(''' + Dir + ''', [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force"');
end;

procedure ShutDownApp;
begin
  KillProcess('{{EXECUTABLE_NAME}}');
  HelperHeld := RunHidden('sc.exe', 'config "' + HelperService + '" start= disabled') = 0;
  RunHidden('net.exe', 'stop "' + HelperService + '"');
  KillProcess(HelperService + '.exe');
  KillCore;
  Sleep(1000);
end;

procedure ReleaseHelper;
begin
  if not HelperHeld then
    Exit;
  HelperHeld := False;
  RunHidden('sc.exe', 'config "' + HelperService + '" start= auto');
  RunHidden('sc.exe', 'start "' + HelperService + '"');
end;

function IsAppInstalled(): Boolean;
var
  UninstallKey: String;
begin
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{{APP_ID}}_is1';
  Result := RegKeyExists(HKEY_LOCAL_MACHINE, UninstallKey) or
            RegKeyExists(HKEY_CURRENT_USER, UninstallKey);
end;

function IsUpgradeInstallation(): Boolean;
begin
  Result := IsUpgrade;
end;

function GetInstalledVersion(): String;
var
  UninstallKey: String;
  Version: String;
begin
  Result := '';
  UninstallKey := 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{{APP_ID}}_is1';
  if RegQueryStringValue(HKEY_LOCAL_MACHINE, UninstallKey, 'DisplayVersion', Version) then
    Result := Version
  else if RegQueryStringValue(HKEY_CURRENT_USER, UninstallKey, 'DisplayVersion', Version) then
    Result := Version;
end;

function InitializeSetup(): Boolean;
begin
  IsUpgrade := IsAppInstalled();
  if IsUpgrade then
    PreviousVersion := GetInstalledVersion();
  Result := True;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  { Refuse a directory containing another client before changing any services. }
  if FileExists(ExpandConstant('{app}\FlClashX.exe')) or
     FileExists(ExpandConstant('{app}\FlClashXPre.exe')) or
     FileExists(ExpandConstant('{app}\FlClash.exe')) or
     FileExists(ExpandConstant('{app}\FlClashXHelperService.exe')) or
     FileExists(ExpandConstant('{app}\FlClashXPreHelperService.exe')) or
     FileExists(ExpandConstant('{app}\FlClashHelperService.exe')) or
     FileExists(ExpandConstant('{app}\FlClashPreHelperService.exe')) then
  begin
    Result := CustomMessage('ForeignInstallDir');
    Exit;
  end;
  ShutDownApp;
end;

procedure DeinitializeSetup();
begin
  ReleaseHelper;
end;

procedure InitializeWizard();
begin
  if IsUpgrade then
  begin
    WizardForm.Caption := '{{DISPLAY_NAME}} - ' + CustomMessage('Upgrade');
    if PreviousVersion <> '' then
      WizardForm.WelcomeLabel2.Caption :=
        FmtMessage(CustomMessage('InstalledVersion'), [PreviousVersion]) + #13#10 + #13#10 +
        FmtMessage(CustomMessage('WillInstall'), ['{{APP_VERSION}}']) + #13#10 + #13#10 +
        CustomMessage('ContinueHint')
    else
      WizardForm.WelcomeLabel2.Caption :=
        CustomMessage('InstalledUnknown') + #13#10 + #13#10 +
        FmtMessage(CustomMessage('WillInstall'), ['{{APP_VERSION}}']) + #13#10 + #13#10 +
        CustomMessage('ContinueHint');
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  if IsUpgrade then
  begin
    Result := CustomMessage('Upgrade') + NewLine;
    if PreviousVersion <> '' then
      Result := Result + FmtMessage(CustomMessage('CurrentVersion'), [PreviousVersion]) + NewLine;
    Result := Result + FmtMessage(CustomMessage('NewVersion'), ['{{APP_VERSION}}']) + NewLine + NewLine;
  end
  else
    Result := CustomMessage('FreshInstall') + NewLine + NewLine;
  if MemoDirInfo <> '' then
    Result := Result + MemoDirInfo + NewLine + NewLine;
  if MemoGroupInfo <> '' then
    Result := Result + MemoGroupInfo + NewLine + NewLine;
  if MemoTasksInfo <> '' then
    Result := Result + MemoTasksInfo + NewLine;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, 0, 0);
    ReleaseHelper;
  end;
end;

// Only remove per-user entries if they still point at this installation.
procedure RemoveOwnedProtocol(const Scheme: String);
var
  Key, Command: String;
begin
  Key := 'Software\Classes\' + Scheme;
  if RegQueryStringValue(HKEY_CURRENT_USER, Key + '\shell\open\command', '', Command) and
     (CompareText(Command, '"' + ExpandConstant('{app}\{{EXECUTABLE_NAME}}') + '" "%1"') = 0) then
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, Key);
end;

procedure RemoveOwnedAutostart;
var
  Key, Command, Exe: String;
begin
  Key := 'Software\Microsoft\Windows\CurrentVersion\Run';
  Exe := ExpandConstant('{app}\{{EXECUTABLE_NAME}}');
  if RegQueryStringValue(HKEY_CURRENT_USER, Key, '{{DISPLAY_NAME}}', Command) and
     ((CompareText(Command, Exe) = 0) or
      (CompareText(Command, '"' + Exe + '"') = 0) or
      (Pos(Lowercase('"' + Exe + '" '), Lowercase(Command)) = 1)) then
    RegDeleteValue(HKEY_CURRENT_USER, Key, '{{DISPLAY_NAME}}');
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  case CurUninstallStep of
    usUninstall:
    begin
      ShutDownApp;
      RunHidden('sc.exe', 'delete "' + HelperService + '"');
      RemoveOwnedAutostart;
      RemoveOwnedProtocol('flclashz');
      RemoveOwnedProtocol('clashz');
    end;
    usPostUninstall:
    begin
      if DirExists(ExpandConstant('{userappdata}\{{USER_DATA_DIR}}')) then
      begin
        if (not UninstallSilent) and
           (MsgBox(CustomMessage('RemoveUserData'), mbConfirmation, MB_YESNO) = IDYES) then
          DelTree(ExpandConstant('{userappdata}\{{USER_DATA_DIR}}'), True, True, True);
      end;
    end;
  end;
end;

[Languages]
{{LANGUAGES}}

[CustomMessages]
english.Upgrade=Upgrade
english.FreshInstall=New installation
english.InstalledVersion=Version %1 is installed.
english.InstalledUnknown=An installed version was found.
english.WillInstall=Setup will install version %1.
english.ContinueHint=Click Next to continue the upgrade, or Cancel to exit.
english.CurrentVersion=Current version: %1
english.NewVersion=New version: %1
english.RemoveUserData=Remove the application's user data?
english.ForeignInstallDir=Choose a separate folder. This folder belongs to another FlClash application.
russian.Upgrade=Обновление
russian.FreshInstall=Новая установка
russian.InstalledVersion=Обнаружена установленная версия %1.
russian.InstalledUnknown=Обнаружена установленная версия программы.
russian.WillInstall=Программа установит версию %1.
russian.ContinueHint=Нажмите «Далее», чтобы продолжить обновление, или «Отмена», чтобы выйти.
russian.CurrentVersion=Текущая версия: %1
russian.NewVersion=Новая версия: %1
russian.RemoveUserData=Удалить пользовательские данные программы?
russian.ForeignInstallDir=Выберите отдельную папку. Эта папка принадлежит другому приложению FlClash.
chineseSimplified.Upgrade=升级
chineseSimplified.FreshInstall=全新安装
chineseSimplified.InstalledVersion=已安装版本 %1。
chineseSimplified.InstalledUnknown=检测到已安装的版本。
chineseSimplified.WillInstall=安装程序将安装版本 %1。
chineseSimplified.ContinueHint=点击“下一步”继续升级，或点击“取消”退出。
chineseSimplified.CurrentVersion=当前版本：%1
chineseSimplified.NewVersion=新版本：%1
chineseSimplified.RemoveUserData=是否删除应用程序的用户数据？
chineseSimplified.ForeignInstallDir=请选择单独的目录。此目录属于其他 FlClash 应用。

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce; Check: not IsUpgradeInstallation

[Files]
Source: "{{SOURCE_DIR}}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
Root: HKLM; Subkey: "Software\Classes\flclashz"; ValueType: string; ValueName: ""; ValueData: "URL:FlClashZ"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\flclashz"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKLM; Subkey: "Software\Classes\flclashz\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{{EXECUTABLE_NAME}},0"
Root: HKLM; Subkey: "Software\Classes\flclashz\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{{EXECUTABLE_NAME}}"" ""%1"""
Root: HKLM; Subkey: "Software\Classes\clashz"; ValueType: string; ValueName: ""; ValueData: "URL:FlClashZ"; Flags: uninsdeletekey
Root: HKLM; Subkey: "Software\Classes\clashz"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKLM; Subkey: "Software\Classes\clashz\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{{EXECUTABLE_NAME}},0"
Root: HKLM; Subkey: "Software\Classes\clashz\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{{EXECUTABLE_NAME}}"" ""%1"""

[Icons]
Name: "{autoprograms}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"
Name: "{autodesktop}\{{DISPLAY_NAME}}"; Filename: "{app}\{{EXECUTABLE_NAME}}"; Tasks: desktopicon

[Run]
Filename: "{app}\{{EXECUTABLE_NAME}}"; Description: "{cm:LaunchProgram,{{DISPLAY_NAME}}}"; Flags: {{RUN_FLAGS}} nowait postinstall skipifsilent
