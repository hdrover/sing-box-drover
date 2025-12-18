unit Logger;

interface

uses
  System.SysUtils, System.SyncObjs;

type
  TLogger = class
  private
    FFile: TextFile;
    FLock: TCriticalSection;
    FIsOpen: boolean;
    FEnabled: boolean;
  public
    constructor Create(AFilePath: string);
    destructor Destroy; override;
    procedure Log(AMessage: string);
  end;

implementation

constructor TLogger.Create(AFilePath: string);
begin
  FLock := TCriticalSection.Create;
  FEnabled := AFilePath <> '';

  if FEnabled then
  begin
    AssignFile(FFile, AFilePath);
    if FileExists(AFilePath) then
      Append(FFile)
    else
      Rewrite(FFile);
    FIsOpen := true;
  end
  else
  begin
    FIsOpen := false;
  end;
end;

destructor TLogger.Destroy;
begin
  if FIsOpen then
    CloseFile(FFile);
  FreeAndNil(FLock);
  inherited;
end;

procedure TLogger.Log(AMessage: string);
var
  line: string;
begin
  if not FEnabled then
    exit;

  FLock.Enter;
  try
    line := FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + AMessage;
    Writeln(FFile, line);
    Flush(FFile);
  finally
    FLock.Leave;
  end;
end;

end.
