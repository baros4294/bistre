; Bistre Windows x64 per-user installer (Inno Setup 6)
; Installs binaries into %LocalAppData%\Programs\Bistre so %LocalAppData%\Bistre user data
; (SQLite WAL database, encrypted vault, attachments) is never touched on upgrade or uninstall.

#ifndef MyAppVersion
  #define MyAppVersion "0.1.2"
#endif
#ifndef StageDir
  #define StageDir "..\..\stage"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "bistre-v0.1.2-windows-x64-setup"
#endif

[Setup]
AppId={{8E5F7B43-2C14-4A6A-9C3E-5A7F1D8B9012}
AppName=Bistre
AppVersion={#MyAppVersion}
AppVerName=Bistre {#MyAppVersion}
AppPublisher=Bistre
AppPublisherURL=https://github.com/baros4294/bistre
AppSupportURL=https://github.com/baros4294/bistre/issues
AppUpdatesURL=https://github.com/baros4294/bistre/releases
DefaultDirName={autopf}\Bistre
DefaultGroupName=Bistre
DisableProgramGroupPage=yes
LicenseFile=..\..\LICENSE
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
SetupIconFile=..\..\apps\bistre_app\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\bistre_app.exe
UninstallDisplayName=Bistre
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes
CloseApplicationsFilter=bistre_app.exe,bistre-daemon.exe,bistre-updater.exe
RestartApplications=no

[InstallDelete]
Type: filesandordirs; Name: "{app}\data"

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Bistre"; Filename: "{app}\bistre_app.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\Bistre"; Filename: "{app}\bistre_app.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\bistre_app.exe"; Description: "{cm:LaunchProgram,Bistre}"; Flags: nowait postinstall skipifsilent

[Code]
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'Bistre');
  end;
end;
