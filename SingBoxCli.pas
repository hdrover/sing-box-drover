unit SingBoxCli;

interface

uses
  Winapi.Windows, System.SysUtils, System.SyncObjs, Logger;

type
  TSingBoxCli = class
  private
    FCorePath: string;
    FLogger: TLogger;
    FLock: TCriticalSection;
    FVersion: string;
    FVersionChecked: boolean;

    function RunCli(const AArgs: string; ATimeoutMs: DWORD; AMaxOutputBytes: integer; out AOutput: string): boolean;
    function FetchVersion: string;
    procedure Log(const AMessage: string);
  public
    constructor Create(const ACorePath: string; ALogger: TLogger);
    destructor Destroy; override;

    function GetVersion: string;
  end;

implementation

constructor TSingBoxCli.Create(const ACorePath: string; ALogger: TLogger);
begin
  FCorePath := ACorePath;
  FLogger := ALogger;
  FLock := TCriticalSection.Create;
end;

destructor TSingBoxCli.Destroy;
begin
  FreeAndNil(FLock);
  inherited;
end;

function TSingBoxCli.GetVersion: string;
var
  justFetched: boolean;
begin
  justFetched := false;
  FLock.Enter;
  try
    if not FVersionChecked then
    begin
      FVersion := FetchVersion;
      FVersionChecked := true;
      justFetched := true;
    end;
    result := FVersion;
  finally
    FLock.Leave;
  end;

  if justFetched then
  begin
    if result <> '' then
      Log('Detected version: ' + result)
    else
      Log('Failed to detect version.');
  end;
end;

function TSingBoxCli.FetchVersion: string;
const
  WAIT_TIMEOUT_MS = 5000;
  MAX_OUTPUT_SIZE = 8192;
  MAX_VERSION_LENGTH = 64;
  VERSION_PREFIX = 'sing-box version ';
var
  outputText, firstLine: string;
  nlPos: integer;
begin
  result := '';

  if not RunCli('version', WAIT_TIMEOUT_MS, MAX_OUTPUT_SIZE, outputText) then
    exit;

  nlPos := Pos(#10, outputText);
  if nlPos > 0 then
    firstLine := copy(outputText, 1, nlPos - 1)
  else
    firstLine := outputText;
  firstLine := trim(firstLine);

  if not firstLine.StartsWith(VERSION_PREFIX) then
    exit;

  result := trim(copy(firstLine, length(VERSION_PREFIX) + 1, MAX_VERSION_LENGTH));
  if length(result) >= MAX_VERSION_LENGTH then
    result := '';
end;

function TSingBoxCli.RunCli(const AArgs: string; ATimeoutMs: DWORD; AMaxOutputBytes: integer;
  out AOutput: string): boolean;
const
  TERMINATE_WAIT_MS = 1000;
var
  secAttr: TSecurityAttributes;
  stdoutRead, stdoutWrite, stdinNull: THandle;
  si: TStartupInfo;
  pi: TProcessInformation;
  cmdLine, workDir: string;
  outputBytes: TBytes;
  bytesRead: DWORD;
  totalBytes: integer;
  savedErrorMode: UINT;
  processStarted: boolean;

  procedure SafeCloseHandle(var h: THandle);
  begin
    if (h <> 0) and (h <> INVALID_HANDLE_VALUE) then
      CloseHandle(h);
    h := 0;
  end;

begin
  result := false;
  AOutput := '';

  stdoutRead := 0;
  stdoutWrite := 0;
  stdinNull := 0;
  ZeroMemory(@pi, sizeOf(pi));

  try
    try
      ZeroMemory(@secAttr, sizeOf(secAttr));
      secAttr.nLength := sizeOf(secAttr);
      secAttr.bInheritHandle := true;

      if not CreatePipe(stdoutRead, stdoutWrite, @secAttr, 0) then
        exit;

      if not SetHandleInformation(stdoutRead, HANDLE_FLAG_INHERIT, 0) then
        exit;

      stdinNull := CreateFile('NUL', GENERIC_READ, FILE_SHARE_READ or FILE_SHARE_WRITE, @secAttr, OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL, 0);
      if stdinNull = INVALID_HANDLE_VALUE then
        exit;

      ZeroMemory(@si, sizeOf(si));
      si.cb := sizeOf(si);
      si.dwFlags := STARTF_USESTDHANDLES;
      si.hStdInput := stdinNull;
      si.hStdOutput := stdoutWrite;
      si.hStdError := stdoutWrite;

      if AArgs <> '' then
        cmdLine := format('"%s" %s', [FCorePath, AArgs])
      else
        cmdLine := format('"%s"', [FCorePath]);
      workDir := ExtractFileDir(FCorePath);

      savedErrorMode := SetErrorMode(SEM_FAILCRITICALERRORS or SEM_NOGPFAULTERRORBOX or SEM_NOOPENFILEERRORBOX);
      try
        processStarted := CreateProcess(nil, PChar(cmdLine), nil, nil, true, CREATE_NO_WINDOW, nil,
          PChar(workDir), si, pi);
      finally
        SetErrorMode(savedErrorMode);
      end;
      if not processStarted then
        exit;

      // Parent must close its copy of the write end so ReadFile sees EOF when the child exits.
      SafeCloseHandle(stdoutWrite);
      SafeCloseHandle(stdinNull);

      if WaitForSingleObject(pi.hProcess, ATimeoutMs) <> WAIT_OBJECT_0 then
      begin
        TerminateProcess(pi.hProcess, 1);
        WaitForSingleObject(pi.hProcess, TERMINATE_WAIT_MS);
        exit;
      end;

      setLength(outputBytes, AMaxOutputBytes);
      totalBytes := 0;

      while totalBytes < AMaxOutputBytes do
      begin
        bytesRead := 0;
        if not ReadFile(stdoutRead, outputBytes[totalBytes], DWORD(AMaxOutputBytes - totalBytes), bytesRead, nil) then
        begin
          if GetLastError <> ERROR_BROKEN_PIPE then
            exit;
          break;
        end;
        if bytesRead = 0 then
          break;
        inc(totalBytes, bytesRead);
      end;

      setLength(outputBytes, totalBytes);
      AOutput := TEncoding.UTF8.GetString(outputBytes);
      result := true;
    except
      AOutput := '';
      result := false;
    end;
  finally
    SafeCloseHandle(stdoutRead);
    SafeCloseHandle(stdoutWrite);
    SafeCloseHandle(stdinNull);
    SafeCloseHandle(pi.hProcess);
    SafeCloseHandle(pi.hThread);
  end;
end;

procedure TSingBoxCli.Log(const AMessage: string);
begin
  FLogger.Log('SingBoxCli', AMessage);
end;

end.
