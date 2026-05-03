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

    procedure DoClose;
  public
    constructor Create(AFilePath: string);
    destructor Destroy; override;
    procedure Log(const ASection, AMessage: string);
    procedure Close;
  end;

implementation

constructor TLogger.Create(AFilePath: string);
begin
  FLock := TCriticalSection.Create;
  FIsOpen := false;

  if AFilePath = '' then
    exit;

  try
    AssignFile(FFile, AFilePath);
    if FileExists(AFilePath) then
      Append(FFile)
    else
      Rewrite(FFile);
    FIsOpen := true;
  except
    FIsOpen := false;
  end;
end;

destructor TLogger.Destroy;
begin
  DoClose;
  FreeAndNil(FLock);
  inherited;
end;

procedure TLogger.DoClose;
begin
  if not FIsOpen then
    exit;
  try
    CloseFile(FFile);
  except
  end;
  FIsOpen := false;
end;

procedure TLogger.Close;
begin
  FLock.Enter;
  try
    DoClose;
  finally
    FLock.Leave;
  end;
end;

procedure TLogger.Log(const ASection, AMessage: string);
var
  line, prefix: string;
begin
  if not FIsOpen then
    exit;

  FLock.Enter;
  try
    if not FIsOpen then
      exit;
    if ASection <> '' then
      prefix := '[' + ASection + '] '
    else
      prefix := '';
    line := trim(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) + ' ' + prefix + AMessage);
    try
      Writeln(FFile, line);
      Flush(FFile);
    except
      DoClose;
    end;
  finally
    FLock.Leave;
  end;
end;

end.
