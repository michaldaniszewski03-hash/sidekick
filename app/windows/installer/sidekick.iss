; Inno Setup script for the Sidekick Windows installer.
;
; Build the app first (flutter build windows --release), then:
;   iscc /DAppVersion=0.1.0 windows\installer\sidekick.iss
; The installer lands in build\installer\SidekickSetup-<version>.exe.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define AppName "Sidekick"
#define AppExe "sidekick.exe"
#define BuildDir "..\..\build\windows\x64\runner\Release"

[Setup]
; Keep this AppId forever: Windows uses it to recognise upgrades.
AppId={{8F3C2A51-6B7E-4D2F-9C1A-5E4B3D2F1A60}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Sidekick
AppPublisherURL=https://github.com/michaldaniszewski03-hash/sidekick
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Admin rights are needed for Program Files and the firewall rule.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\build\installer
OutputBaseFilename=SidekickSetup-{#AppVersion}
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Close a running Sidekick before upgrading it.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
; Let other devices on private networks reach Sidekick, so Windows Firewall
; doesn't block discovery or pop up a prompt on first launch. Remove any old
; rule first so upgrades don't pile up duplicates.
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#AppName}"""; Flags: runhidden waituntilterminated
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#AppName}"" dir=in action=allow program=""{app}\{#AppExe}"" enable=yes profile=private,domain"; Flags: runhidden waituntilterminated
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#AppName}"""; Flags: runhidden waituntilterminated; RunOnceId: "RemoveFirewallRule"
