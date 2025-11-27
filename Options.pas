unit Options;

interface

uses
  Windows,
  System.SysUtils,
  IniFiles;

const
  OPTIONS_FILENAME = 'sing-box-drover.ini';
  SECTION_MAIN = 'sing-box-drover';

type
  TDroverOptions = record
    sbDir: string;
    sbConfigFile: string;
    systemProxyAuto: boolean;
  end;

function LoadOptions(filename: string): TDroverOptions;

implementation

function LoadOptions(filename: string): TDroverOptions;
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

        result.systemProxyAuto := ReadBool(SECTION_MAIN, 'system-proxy-auto', false);
      end;
    finally
      f.Free;
    end;
  except
  end;
end;

end.
