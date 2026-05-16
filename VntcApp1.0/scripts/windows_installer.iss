#ifndef MyAppName
  #define MyAppName "VNT GUI"
#endif

#ifndef MyAppVersion
  #define MyAppVersion "0.0.0"
#endif

#ifndef MyAppPublisher
  #define MyAppPublisher "lmq8267"
#endif

#ifndef MyAppURL
  #define MyAppURL "https://github.com/lmq8267/vntAPP"
#endif

#ifndef MyAppExeName
  #define MyAppExeName "vnt_app.exe"
#endif

#ifndef MyRootDir
  #error MyRootDir is required
#endif

#ifndef MyDistDir
  #error MyDistDir is required
#endif

#ifndef MyOutputDir
  #error MyOutputDir is required
#endif

[Setup]
AppId={{C0A5F7C4-9F18-4D91-9D7E-9A0D0F4DB8CB}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
DisableDirPage=no
DisableProgramGroupPage=yes
LicenseFile={#MyRootDir}\LICENSE
OutputDir={#MyOutputDir}
OutputBaseFilename=VNT_GUI_{#MyAppVersion}_Setup
SetupIconFile={#MyRootDir}\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
Source: "{#MyDistDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
