; Установщик AstatVPN для Windows (Inno Setup 6.3 или новее).
;
; Порядок сборки:
;   1. tool/build_core_windows.sh        — служба astat-helper.exe, wintun.dll и геобазы (можно на любой системе)
;   2. flutter build windows --release   — на Windows; служба и её файлы попадут в каталог сборки сами
;   3. iscc windows\installer\astatvpn.iss            (x64)
;      iscc /DArch=arm64 windows\installer\astatvpn.iss  (ARM64)
;      версия: /DAppVersion=0.1.0
;
; Приложение ставится для всех пользователей в Program Files, и каталог выбрать нельзя. Это сделано намеренно:
; служба работает с правами системы и загружает wintun.dll и геобазы из своего каталога, поэтому каталог
; должен быть закрыт от записи для обычных программ. Program Files таким и является.

#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef BuildDir
  #define BuildDir "..\..\build\windows\" + Arch + "\runner\Release"
#endif

#define AppName "AstatVPN"
#define AppExe "astatvpn.exe"
#define HelperExe "astat-helper.exe"

[Setup]
AppId={{5713B1D7-B123-48C0-9B46-304117171000}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=AstatVPN
DefaultDirName={autopf}\{#AppName}
DisableDirPage=yes
DisableProgramGroupPage=yes
UsePreviousAppDir=no
PrivilegesRequired=admin
MinVersion=10.0.17763
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
OutputDir=..\..\build\installer
OutputBaseFilename=AstatVPN-{#AppVersion}-{#Arch}-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать значок на рабочем столе"; Flags: unchecked

[Files]
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; Библиотеки Microsoft Visual C++ (msvcp140.dll, vcruntime140.dll, vcruntime140_1.dll): приложению Flutter они нужны,
; а в чистой Windows их может не быть. Если положить их в windows\installer\redist\<x64|arm64>\, они попадут в установщик.
Source: "redist\{#Arch}\*.dll"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "Запустить {#AppName}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
; останавливает подключение (адаптер, маршруты и фильтры убираются) и удаляет службу
Filename: "{app}\{#HelperExe}"; Parameters: "uninstall"; Flags: runhidden waituntilterminated; RunOnceId: "AstatVPNHelperRemove"

[Code]
// Перед копированием файлов останавливаем и удаляем прежнюю службу: иначе astat-helper.exe и wintun.dll заняты.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Helper: String;
  Code: Integer;
begin
  Result := '';
  Helper := ExpandConstant('{app}\{#HelperExe}');
  if FileExists(Helper) then
  begin
    if (not Exec(Helper, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, Code)) or (Code <> 0) then
      Result := 'Не удалось остановить службу AstatVPN прежней версии. Перезагрузите компьютер и запустите установку снова.';
  end;
end;

// После копирования регистрируем и запускаем службу. Без неё приложение не сможет подключаться.
procedure CurStepChanged(CurStep: TSetupStep);
var
  Helper: String;
  Code: Integer;
begin
  if CurStep <> ssPostInstall then
    exit;
  Helper := ExpandConstant('{app}\{#HelperExe}');
  if not FileExists(Helper) then
  begin
    MsgBox('В установщике нет файла службы ({#HelperExe}). Приложение установлено, но подключаться не сможет.', mbError, MB_OK);
    exit;
  end;
  if (not Exec(Helper, 'install', '', SW_HIDE, ewWaitUntilTerminated, Code)) or (Code <> 0) then
    MsgBox('Не удалось установить службу AstatVPN (код ' + IntToStr(Code) + '). Приложение установлено, но подключаться не сможет. Запустите установку ещё раз.', mbError, MB_OK);
end;
