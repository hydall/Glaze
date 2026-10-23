; Inno Setup script for the Windows build of Glaze.
;
; Built by windows/installer/build_installer.ps1, which reads the version from
; pubspec.yaml and passes everything below as /D defines. Run that script
; rather than ISCC directly; docs/WINDOWS_INSTALLER.md has the details.
;
; Installs per user (no administrator rights) and never touches the user's data
; on install or update. Data lives outside the install folder:
;   %APPDATA%\<data folder>   database, images, logs  (Glaze / Glaze-nightly)
;   %APPDATA%\com.glaze\Glaze shared_preferences, shared by every channel
;   {app}\Glaze.exe.WebView2  WebView2 profile (catalog logins, cookies)
; Uninstall only removes them when the user says yes to the question it asks.

#ifndef AppVersion
  #error AppVersion is not defined; build through build_installer.ps1
#endif
#ifndef NumericVersion
  #define NumericVersion AppVersion
#endif
#ifndef Channel
  #define Channel "nightly"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build\windows\installer"
#endif

; Each channel is its own app to Windows — separate entry in Apps, install
; folder and Start menu shortcut — the same way the channels already keep
; separate data folders (lib/core/constants/build_channel.dart), so stable and
; nightly install side by side instead of over each other.
#if Channel == "stable"
  #define AppId "{A043B843-79AA-4F0D-BEEC-DB7F9B964227}"
  #define AppName "Glaze"
  #define DataFolder "Glaze"
#elif Channel == "nightly"
  #define AppId "{C566B871-18C9-4333-BF1C-E659CAD46A96}"
  #define AppName "Glaze Nightly"
  #define DataFolder "Glaze-nightly"
#else
  ; Any other BUILD_CHANNEL (a local test build) gets an id of its own too.
  #define AppId "{F96D8550-B3AC-49FF-BB32-18C25415EF0C}"
  #define AppName "Glaze (" + Channel + ")"
  #define DataFolder "Glaze-" + Channel
#endif

#ifndef OutputBaseFilename
  #define OutputBaseFilename "Glaze-" + Channel + "-" + AppVersion + "-windows-setup"
#endif

#define ExeName "Glaze.exe"

; The legacy Electron build (com.hydall.glaze, electron-builder) registers this
; uninstall key — a UUIDv5 of its appId, the same on every machine — and lives
; in %LOCALAPPDATA%\Programs\glaze with its data in %APPDATA%\Glaze. That is why
; this installer uses a folder of its own, and why uninstalling the stable
; channel keeps %APPDATA%\Glaze while the old app is still there.
#define LegacyUninstallKey "Software\Microsoft\Windows\CurrentVersion\Uninstall\6aaa01ad-0320-5b69-a360-2f2e2354fdec"

[Setup]
AppId={{#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Glaze
AppPublisherURL=https://github.com/hydall/Glaze
AppSupportURL=https://github.com/hydall/Glaze/issues
AppUpdatesURL=https://github.com/hydall/Glaze/releases
VersionInfoVersion={#NumericVersion}
VersionInfoProductVersion={#NumericVersion}
VersionInfoDescription={#AppName} Setup
; %LOCALAPPDATA%\Programs\com.glaze\<name>: per user, no UAC prompt. Not
; %LOCALAPPDATA%\Programs\Glaze — the legacy Electron app already sits there.
PrivilegesRequired=lowest
DefaultDirName={userpf}\com.glaze\{#AppName}
DisableDirPage=auto
DisableProgramGroupPage=yes
UsePreviousAppDir=yes
UsePreviousTasks=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#ExeName}
UninstallDisplayName={#AppName}
WizardStyle=modern
ShowLanguageDialog=auto
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
; A running Glaze is closed through the Restart Manager before files are
; replaced. The app relaunches itself after an in-app update (see [Run]), so
; the Restart Manager is not asked to.
CloseApplications=force
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
en.AskDeleteData=Also delete your Glaze data — characters, chats, presets and settings?%n%n%1%n%nChoose No to keep it: installing Glaze again picks it up where you left off.
ru.AskDeleteData=Удалить и ваши данные Glaze — персонажей, чаты, пресеты и настройки?%n%n%1%n%nВыберите «Нет», чтобы сохранить их: после повторной установки Glaze всё будет на месте.
en.KeepDataLegacy=Your Glaze data in %1 was kept: the old Glaze app is still installed and keeps its data in the same folder.
ru.KeepDataLegacy=Данные Glaze в %1 сохранены: старое приложение Glaze ещё установлено и хранит данные в той же папке.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; data\ is pure build output (flutter_assets, AOT snapshot, ICU data). Wiping
; it keeps assets removed in a newer version from lingering. Nothing of the
; user's lives there — the WebView2 profile is a sibling, Glaze.exe.WebView2.
Type: filesandordirs; Name: "{app}\data"

[Files]
; A Release folder the app has already run from holds a WebView2 profile;
; shipping it would overwrite the user's own (logins) on every update.
Source: "{#SourceDir}\*"; DestDir: "{app}"; Excludes: "\Glaze.exe.WebView2"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#ExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
; The in-app updater runs setup with /VERYSILENT /RELAUNCH=1 and quits; this
; brings Glaze back once the files are in place.
Filename: "{app}\{#ExeName}"; Flags: nowait; Check: ShouldRelaunch

[Code]
var
  DeleteUserData: Boolean;

function ShouldRelaunch: Boolean;
begin
  Result := WizardSilent and (ExpandConstant('{param:RELAUNCH|0}') = '1');
end;

function DataDir: String;
begin
  Result := ExpandConstant('{userappdata}\{#DataFolder}');
end;

function LegacyElectronInstalled: Boolean;
begin
  Result := RegKeyExists(HKCU, '{#LegacyUninstallKey}') or
    RegKeyExists(HKLM, '{#LegacyUninstallKey}');
end;

// Preferences live in one folder for every channel, so they only go with the
// last channel's data.
function OtherChannelDataExists: Boolean;
var
  Own: String;
begin
  Own := Lowercase('{#DataFolder}');
  Result := ((Own <> 'glaze') and
      DirExists(ExpandConstant('{userappdata}\Glaze'))) or
    ((Own <> 'glaze-nightly') and
      DirExists(ExpandConstant('{userappdata}\Glaze-nightly')));
end;

// Asked once the user has confirmed the uninstall itself, so cancelling that
// first prompt never gets as far as a question about data.
procedure AskAboutUserData;
begin
  DeleteUserData := False;
  // A silent uninstall never deletes data; it has nobody to ask.
  if UninstallSilent or not DirExists(DataDir) then
    Exit;
  if (Lowercase('{#DataFolder}') = 'glaze') and LegacyElectronInstalled then
  begin
    MsgBox(FmtMessage(CustomMessage('KeepDataLegacy'), [DataDir]),
      mbInformation, MB_OK);
    Exit;
  end;
  DeleteUserData := MsgBox(
    FmtMessage(CustomMessage('AskDeleteData'), [DataDir]),
    mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    AskAboutUserData;
  if (CurUninstallStep <> usPostUninstall) or not DeleteUserData then
    Exit;
  DelTree(DataDir, True, True, True);
  DelTree(ExpandConstant('{app}\Glaze.exe.WebView2'), True, True, True);
  if not OtherChannelDataExists then
    DelTree(ExpandConstant('{userappdata}\com.glaze\Glaze'), True, True, True);
  RemoveDir(ExpandConstant('{app}'));
end;
