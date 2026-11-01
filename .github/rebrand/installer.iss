; Repackages an already verified Actelyo application folder with its product logo.
; Same AppId as the original installer, so installing it upgrades the previous version in place.
#ifndef AppSource
  #error AppSource is required
#endif
[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
VersionInfoCompany=Actelyo
AppPublisher=Actelyo
AppPublisherURL=https://actelyo.com
DefaultDirName={localappdata}\Programs\{#DirName}
DefaultGroupName={#AppName}
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBase}
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\{#ExeName}
Compression=lzma2/fast
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
[Languages]
Name: "french"; MessagesFile: "compiler:Languages\French.isl"
[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Excludes: "unins*.exe,unins*.dat,unins*.msg"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#AppIcon}"; DestDir: "{app}"; DestName: "actelyo-product.ico"; Flags: ignoreversion
[Icons]
Name: "{autoprograms}\{#ShortcutName}"; Filename: "{app}\{#ExeName}"; IconFilename: "{app}\{#ExeName}"
Name: "{autodesktop}\{#ShortcutName}"; Filename: "{app}\{#ExeName}"; IconFilename: "{app}\{#ExeName}"
[Run]
Filename: "{app}\{#ExeName}"; Description: "Ouvrir {#ShortcutName}"; Flags: nowait postinstall skipifsilent
