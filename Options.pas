unit Options;

interface

uses
  Windows,
  System.SysUtils,
  System.StrUtils,
  IniFiles;

const
  OPTIONS_FILENAME = 'sing-box-drover.ini';
  SECTION_MAIN = 'sing-box-drover';

type
  TTunStartMode = (tsmOn, tsmOff);
  TSelectorMenuLayout = (smlAuto, smlFlat, smlNested);

  TDroverOptions = record
    sbDir: string;
    sbConfigFile: string;
    systemProxyAuto: boolean;
    tunStartMode: TTunStartMode;
    selectorMenuLayout: TSelectorMenuLayout;
    logFile: string;

    class function Load(filename: string): TDroverOptions; static;
  private
    class function ParseTunStartMode(s: string): TTunStartMode; static;
    class function ParseSelectorMenuLayout(s: string): TSelectorMenuLayout; static;
  end;

implementation

class function TDroverOptions.ParseTunStartMode(s: string): TTunStartMode;
begin
  s := trim(LowerCase(s));
  if MatchStr(s, ['off', '0', '']) then
    exit(TTunStartMode.tsmOff)
  else
    exit(TTunStartMode.tsmOn);
end;

class function TDroverOptions.ParseSelectorMenuLayout(s: string): TSelectorMenuLayout;
begin
  s := trim(LowerCase(s));
  if s = 'flat' then
    exit(TSelectorMenuLayout.smlFlat)
  else if s = 'nested' then
    exit(TSelectorMenuLayout.smlNested)
  else
    exit(TSelectorMenuLayout.smlAuto);
end;

class function TDroverOptions.Load(filename: string): TDroverOptions;
var
  s, path, currentDir: string;
  f: TIniFile;
begin
  currentDir := IncludeTrailingPathDelimiter(ExtractFilePath(filename));

  result := Default (TDroverOptions);

  try
    f := TIniFile.Create(filename);
    try
      with f do
      begin
        s := ReadString(SECTION_MAIN, 'sb-dir', '');
        if s = '' then
          s := currentDir
        else
          s := IncludeTrailingPathDelimiter(s);
        result.sbDir := s;

        s := ReadString(SECTION_MAIN, 'sb-config-file', 'config.json');
        if not s.Contains(':') then
        begin
          for path in [currentDir + s, result.sbDir + s] do
          begin
            if FileExists(path) then
            begin
              s := path;
              break;
            end;
          end;
        end;
        result.sbConfigFile := s;

        result.tunStartMode := ParseTunStartMode(ReadString(SECTION_MAIN, 'tun-start-mode', ''));
        result.systemProxyAuto := ReadBool(SECTION_MAIN, 'system-proxy-auto', false);
        result.selectorMenuLayout := ParseSelectorMenuLayout(ReadString(SECTION_MAIN, 'selector-menu-layout', ''));

        s := ReadString(SECTION_MAIN, 'log-file', '');
        if (s <> '') and (not s.Contains(':')) then
        begin
          s := currentDir + s;
        end;
        result.logFile := s;
      end;
    finally
      f.Free;
    end;
  except
  end;
end;

end.
