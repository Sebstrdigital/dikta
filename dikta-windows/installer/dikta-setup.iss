; Dikta Windows Installer
; Inno Setup 6 Script
; Build: dotnet publish -c Release -r win-x64 --self-contained true -o publish/
; Then compile this script with Inno Setup 6

#define MyAppName "Dikta"
#define MyAppVersion "1.1"
#define MyAppPublisher "Dua Digital"
#define MyAppURL "https://dikta.app"
#define MyAppExeName "DiktaWindows.exe"

[Setup]
; NOTE: The AppId value uniquely identifies this application.
; Do not change it once the installer is distributed.
AppId={{E8A4C9D1-5F23-4B87-A3E6-2D1F8C9B4E73}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
OutputDir=output
OutputBaseFilename=DiktaSetup-{#MyAppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; Require 64-bit Windows
ArchitecturesInstallIn64BitMode=x64
ArchitecturesAllowed=x64
; Minimum Windows 10
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "startatlogin"; Description: "Start {#MyAppName} automatically when I log in"; GroupDescription: "Additional tasks:"; Flags: unchecked

[Files]
; Include all files from the publish directory (relative to this .iss file)
Source: "..\publish\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Registry]
; Start at Login — only installed if the user selected the task
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#MyAppName}"; ValueData: """{app}\{#MyAppExeName}"""; Flags: uninsdeletevalue; Tasks: startatlogin

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Remove any leftover files not tracked by the installer
Type: filesandordirs; Name: "{app}"
