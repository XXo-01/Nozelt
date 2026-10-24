; Nozelt Windows installer (Inno Setup 6).
; Build: ISCC.exe /DAppVersion=1.0.0 installer\nozelt.iss
; Installs the portable bundle for the current user. User data stays in
; "portable-data" next to nozelt.exe and survives updates and uninstall.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define BundleDir "..\build\portable\Nozelt"

[Setup]
AppId={{6E1C2F4A-9B7D-4C1E-8A53-0F2D4B6C9E71}
AppName=Nozelt
AppVersion={#AppVersion}
AppPublisher=Nozelt
AppPublisherURL=https://github.com/XXo-01/Nozelt
DefaultDirName={autopf}\Nozelt
DefaultGroupName=Nozelt
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\build\installer
OutputBaseFilename=Nozelt-{#AppVersion}-windows-x64-setup
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\nozelt.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Excludes: "portable-data\*"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Nozelt"; Filename: "{app}\nozelt.exe"
Name: "{autodesktop}\Nozelt"; Filename: "{app}\nozelt.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\nozelt.exe"; Description: "{cm:LaunchProgram,Nozelt}"; Flags: nowait postinstall skipifsilent shellexec

[UninstallRun]
; Never leave the network block behind: stop Nozelt before its files go.
; Only the copy installed here: a portable Nozelt elsewhere keeps running.
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -Command ""Get-Process nozelt -ErrorAction SilentlyContinue | Where-Object {{ $_.Path -like '{app}\*' }} | Stop-Process -Force"""; Flags: runhidden; RunOnceId: "StopNozelt"
