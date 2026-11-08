; Faz Devil Corp - Inno Setup script.
; Build:  "C:\Users\pasha\AppData\Local\Programs\Inno Setup 6\ISCC.exe" installer\fazdevilcorp.iss
; The payload is the exported release build in ..\build (exe + GodotSteam + steam_api64 + app id).

#define MyAppName "Faz Devil Corp"
#define MyAppVersion "0.1.0"
#define MyAppPublisher "FazDevilCorp"
#define MyAppExeName "FazDevilCorp.exe"

[Setup]
AppId={{7C2F4E1B-9A3D-4C58-8F61-2D5B9E4C7A10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\FazDevilCorp
DisableProgramGroupPage=yes
DisableWelcomePage=no
AlwaysShowDirOnReadyPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UninstallDisplayName={#MyAppName} {#MyAppVersion}
UninstallDisplayIcon={app}\{#MyAppExeName}
OutputDir=out
OutputBaseFilename=FazDevilCorp-Setup-{#MyAppVersion}

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\FazDevilCorp.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\libgodotsteam.windows.template_release.x86_64.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\build\steam_api64.dll"; DestDir: "{app}"; Flags: ignoreversion
; Test AppID for Valve's SpaceWar (480). Steam resolves it from the working directory,
; which is why every shortcut below sets WorkingDirectory explicitly.
Source: "..\build\steam_appid.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "HOW_TO_PLAY.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
; Inno 6.7 spells this parameter WorkingDir (WorkingDirectory is rejected).
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autoprograms}\How to play"; Filename: "{app}\HOW_TO_PLAY.txt"
Name: "{autoprograms}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, "&", "&&")}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Session logs under %APPDATA%\Godot\app_userdata\FazDevilCorp are deliberately kept:
; they are the only evidence we get when a two-machine test fails.
