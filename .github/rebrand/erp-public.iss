#ifndef AppSource
  #error AppSource required
#endif
[Setup]
AppId={{798C7D34-BB9C-47E6-B12D-A621C9D36B73}
AppName=Actelyo ERP Desktop
AppVersion=1.8.4
VersionInfoVersion=1.8.4
VersionInfoProductName=Actelyo ERP Desktop
AppPublisher=Actelyo
DefaultDirName={localappdata}\Programs\Actelyo ERP Desktop
DefaultGroupName=Actelyo ERP Desktop
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=Actelyo-ERP-Desktop-Setup-1.8.4-r2-x64
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\Actelyo ERP.exe
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=no
RestartApplications=no
[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
[Icons]
Name: "{autoprograms}\Actelyo ERP Desktop"; Filename: "{app}\Actelyo ERP.exe"; AppUserModelID: "com.actelyo.erp"
Name: "{autodesktop}\Actelyo ERP Desktop"; Filename: "{app}\Actelyo ERP.exe"; AppUserModelID: "com.actelyo.erp"
[Run]
Filename: "{app}\Actelyo ERP.exe"; Description: "Ouvrir Actelyo ERP Desktop"; Flags: nowait postinstall skipifsilent
[Code]
function InitializeSetup(): Boolean;
begin
  Result := not (RegKeyExists(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#NsisKey}') or RegKeyExists(HKLM, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#NsisKey}'));
  if not Result then
    MsgBox('Une installation ERP utilisant un autre programme d''installation est présente. Fermez l''ERP et désinstallez cette version depuis les Applications Windows avant de relancer cet installateur.', mbError, MB_OK);
end;
