unit CoreSupervisor;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  System.Generics.Collections, System.SyncObjs, Logger, SingBoxConfig,
  CoreApiClient;

type
  TSelectorTask = record
    name, value: string;
  end;

  TSelectorTasks = TArray<TSelectorTask>;

  TCoreState = (csStopped, csStarting, csRunning, csStopping, csFailed);

  TCoreEventKind = (cekState, cekError, cekApiReady, cekSelectorDone);

  TCoreEvent = record
    kind: TCoreEventKind;
    state: TCoreState;
    msg: string;
    requestId: NativeInt;
  end;

  TCoreCommandKind = (cmdNone, cmdStart, cmdStop, cmdSetSelectors);

  TCoreCommand = record
    kind: TCoreCommandKind;
    configJson: string;
    selectorTasks: TSelectorTasks;
    requestId: NativeInt;
  end;

  TCoreCommandQueue = TThreadedQueue<TCoreCommand>;

  TCoreEventHandler = procedure(event: TCoreEvent) of object;

  TLogEntryKind = (lekNone, lekTrace, lekDebug, lekInfo, lekWarn, lekError, lekFatal, lekPanic);

  TLogEntryKindPrefix = record
    prefix: string;
    kind: TLogEntryKind;
  end;

  TPipeReader = class(TThread)
  private
    FPipe: THandle;
    FBuffer: TBytes;
    FWrapped: boolean;
    FLock: TCriticalSection;
    procedure AppendBytes(const ABuffer: TBytes; ACount: integer);
  protected
    procedure Execute; override;
  public
    constructor Create(APipe: THandle);
    destructor Destroy; override;
    function GetCapturedText: string;
  end;

  TCoreSupervisor = class(TThread)
  private
    FLogger: TLogger;
    FQueue: TCoreCommandQueue;
    FOnEvent: TCoreEventHandler;
    FJobHandle: THandle;
    FProcessHandle: THandle;
    FProcessId: DWORD;
    FOutputReader: TPipeReader;
    FLastCapturedOutput: string;
    FState: TCoreState;
    FExePath: string;
    FCoreApiClient: TCoreApiClient;
    FApiCheckActive: boolean;
    FApiNextCheckTick: UInt64;
    FApiDeadlineTick: UInt64;

    procedure NotifyEvent(AEvent: TCoreEvent);
    procedure SetStateAndNotify(state: TCoreState; msg: string = '');
    procedure HandleCommand(cmd: TCoreCommand);
    procedure DoStart(configJson: string);
    function SendCtrlCToConsole(processId: DWORD): boolean;
    procedure DoStopGraceful;
    procedure DoSetSelectors(tasks: TSelectorTasks; requestId: NativeInt);
    procedure CheckProcessStatus;
    procedure InitApiCheck;
    procedure CheckApiStatus;
    procedure CleanupProcess;
    procedure DrainReader(var AReader: TPipeReader; out AOutput: string);
    function BuildFailureMessage(const ABase, ACapturedOutput: string): string;
    procedure Log(const AMessage: string);
    function IsProcessRunning: boolean;
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create(AExePath: string; ALogger: TLogger; AClashApiConfig: TClashApiConfig);
    destructor Destroy; override;

    procedure RequestStart(configJson: string);
    procedure RequestStop;
    function RequestSetSelectors(tasks: TSelectorTasks; requestId: NativeInt): boolean;

    property OnEvent: TCoreEventHandler read FOnEvent write FOnEvent;
    property state: TCoreState read FState;
  end;

implementation

const
  STATE_NAMES: array [TCoreState] of string = ('Stopped', 'Starting', 'Running', 'Stopping', 'Failed');
  COMMAND_NAMES: array [TCoreCommandKind] of string = ('None', 'Start', 'Stop', 'SetSelectors');
  MAX_CAPTURE_BYTES = 8 * 1024;
  READ_CHUNK_BYTES = 4 * 1024;
  READER_DRAIN_TIMEOUT_MS = 5000;
  POST_KILL_WAIT_MS = 1000;

constructor TPipeReader.Create(APipe: THandle);
begin
  FPipe := APipe;
  FLock := TCriticalSection.Create;
  SetLength(FBuffer, 0);
  FWrapped := false;
  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TPipeReader.Destroy;
begin
  if (FPipe <> 0) and (FPipe <> INVALID_HANDLE_VALUE) then
    CloseHandle(FPipe);
  FPipe := 0;
  inherited;
  FreeAndNil(FLock);
end;

procedure TPipeReader.Execute;
var
  buf: TBytes;
  bytesRead: DWORD;
begin
  SetLength(buf, READ_CHUNK_BYTES);
  while not Terminated do
  begin
    bytesRead := 0;
    if not ReadFile(FPipe, buf[0], READ_CHUNK_BYTES, bytesRead, nil) then
      break;
    if bytesRead = 0 then
      break;
    AppendBytes(buf, integer(bytesRead));
  end;
end;

procedure TPipeReader.AppendBytes(const ABuffer: TBytes; ACount: integer);
var
  oldLen, newLen, keep: integer;
begin
  if ACount <= 0 then
    exit;

  FLock.Enter;
  try
    if ACount >= MAX_CAPTURE_BYTES then
    begin
      SetLength(FBuffer, MAX_CAPTURE_BYTES);
      move(ABuffer[ACount - MAX_CAPTURE_BYTES], FBuffer[0], MAX_CAPTURE_BYTES);
      FWrapped := true;
      exit;
    end;

    oldLen := Length(FBuffer);
    newLen := oldLen + ACount;

    if newLen <= MAX_CAPTURE_BYTES then
    begin
      SetLength(FBuffer, newLen);
      move(ABuffer[0], FBuffer[oldLen], ACount);
    end
    else
    begin
      keep := MAX_CAPTURE_BYTES - ACount;
      move(FBuffer[oldLen - keep], FBuffer[0], keep);
      SetLength(FBuffer, MAX_CAPTURE_BYTES);
      move(ABuffer[0], FBuffer[keep], ACount);
      FWrapped := true;
    end;
  finally
    FLock.Leave;
  end;
end;

function TPipeReader.GetCapturedText: string;
var
  snapshot: TBytes;
  startIdx, endIdx, i: integer;
  wrapped: boolean;
begin
  result := '';

  FLock.Enter;
  try
    SetLength(snapshot, Length(FBuffer));
    if Length(snapshot) > 0 then
      move(FBuffer[0], snapshot[0], Length(snapshot));
    wrapped := FWrapped;
  finally
    FLock.Leave;
  end;

  if Length(snapshot) = 0 then
    exit;

  endIdx := -1;
  for i := High(snapshot) downto 0 do
    if snapshot[i] = $0A then
    begin
      endIdx := i;
      break;
    end;
  if endIdx < 0 then
    exit;

  startIdx := 0;
  if wrapped then
  begin
    for i := 0 to endIdx do
      if snapshot[i] = $0A then
      begin
        startIdx := i + 1;
        break;
      end;
    if startIdx > endIdx then
      exit;
  end;

  try
    result := TEncoding.UTF8.GetString(snapshot, startIdx, endIdx - startIdx + 1);
  except
    result := '';
    exit;
  end;

  result := trim(result);
end;

function StripSingBoxTimestamp(const line: string): string;
begin
  if (Length(line) >= 27) and ((line[1] = '+') or (line[1] = '-')) and (line[6] = ' ') and (line[11] = '-') and
    (line[14] = '-') and (line[17] = ' ') and (line[20] = ':') and (line[23] = ':') and (line[26] = ' ') then
    result := Copy(line, 27, MaxInt)
  else
    result := line;
end;

function ClassifyLogEntry(const line: string): TLogEntryKind;
const
  LEVELS: array [0 .. 6] of TLogEntryKindPrefix = ((prefix: 'TRACE'; kind: lekTrace), (prefix: 'DEBUG'; kind: lekDebug),
    (prefix: 'INFO'; kind: lekInfo), (prefix: 'WARN'; kind: lekWarn), (prefix: 'ERROR'; kind: lekError),
    (prefix: 'FATAL'; kind: lekFatal), (prefix: 'PANIC'; kind: lekPanic));
var
  rest: string;
  i: integer;
begin
  if line.StartsWith('panic:') then
    exit(lekPanic);
  if line.StartsWith('fatal error:') then
    exit(lekFatal);

  rest := StripSingBoxTimestamp(line);

  for i := low(LEVELS) to high(LEVELS) do
    if rest.StartsWith(LEVELS[i].prefix + '[') or rest.StartsWith(LEVELS[i].prefix + ' ') then
      exit(LEVELS[i].kind);

  result := lekNone;
end;

function ExtractCriticalError(const captured: string): string;
const
  MAX_RESULT_CHARS = 2000;
var
  lines: TArray<string>;
  i, lastIdx: integer;
  lastKind: TLogEntryKind;
  builder: TStringBuilder;
begin
  result := '';
  if captured = '' then
    exit;

  lines := captured.Split([#10], TStringSplitOptions.None);
  for i := 0 to High(lines) do
    if (lines[i] <> '') and (lines[i][Length(lines[i])] = #13) then
      SetLength(lines[i], Length(lines[i]) - 1);

  lastIdx := -1;
  lastKind := lekNone;
  for i := High(lines) downto Low(lines) do
  begin
    lastKind := ClassifyLogEntry(lines[i]);
    if lastKind <> lekNone then
    begin
      lastIdx := i;
      break;
    end;
  end;

  if not(lastKind in [lekFatal, lekPanic]) then
    exit;

  builder := TStringBuilder.Create;
  try
    builder.Append(StripSingBoxTimestamp(lines[lastIdx]));
    for i := lastIdx + 1 to High(lines) do
    begin
      builder.AppendLine;
      builder.Append(lines[i]);
      if builder.Length > MAX_RESULT_CHARS then
        break;
    end;
    result := builder.ToString;
  finally
    builder.Free;
  end;
end;

constructor TCoreSupervisor.Create(AExePath: string; ALogger: TLogger; AClashApiConfig: TClashApiConfig);
begin
  FLogger := ALogger;
  FQueue := TCoreCommandQueue.Create(100, 200, 200);
  FCoreApiClient := TCoreApiClient.Create(AClashApiConfig, ALogger);
  FJobHandle := 0;
  FProcessHandle := 0;
  FProcessId := 0;
  FOutputReader := nil;
  FLastCapturedOutput := '';
  FState := csStopped;
  FExePath := AExePath;
  FApiCheckActive := false;

  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TCoreSupervisor.Destroy;
begin
  Terminate;
  if Assigned(FQueue) then
    FQueue.DoShutDown;

  WaitFor;
  TThread.RemoveQueuedEvents(self);
  CleanupProcess;
  FreeAndNil(FQueue);
  FreeAndNil(FCoreApiClient);

  inherited;
end;

procedure TCoreSupervisor.Execute;
var
  cmd: TCoreCommand;
  waitResult: TWaitResult;
begin
  Log('Supervisor started.');

  while not Terminated do
  begin
    CheckProcessStatus;
    CheckApiStatus;

    waitResult := FQueue.PopItem(cmd);

    case waitResult of
      wrSignaled:
        HandleCommand(cmd);
      wrAbandoned:
        break;
    end;
  end;

  Log('Supervisor stopping...');
  DoStopGraceful;
  Log('Supervisor stopped.');
end;

procedure TCoreSupervisor.TerminatedSet;
begin
  inherited;
  FQueue.DoShutDown;
end;

procedure TCoreSupervisor.CleanupProcess;
begin
  if FJobHandle <> 0 then
  begin
    CloseHandle(FJobHandle);
    FJobHandle := 0;
  end;

  if FProcessHandle <> 0 then
  begin
    CloseHandle(FProcessHandle);
    FProcessHandle := 0;
  end;

  FProcessId := 0;

  DrainReader(FOutputReader, FLastCapturedOutput);
end;

procedure TCoreSupervisor.DrainReader(var AReader: TPipeReader; out AOutput: string);
var
  drained: boolean;
begin
  AOutput := '';
  if not Assigned(AReader) then
    exit;

  drained := WaitForSingleObject(AReader.Handle, READER_DRAIN_TIMEOUT_MS) = WAIT_OBJECT_0;
  if not drained then
  begin
    Log('Output reader did not exit, cancelling I/O.');
    CancelSynchronousIo(AReader.Handle);
    drained := WaitForSingleObject(AReader.Handle, POST_KILL_WAIT_MS) = WAIT_OBJECT_0;
  end;

  AOutput := AReader.GetCapturedText;

  if drained then
    FreeAndNil(AReader)
  else
  begin
    Log('Output reader still blocked; leaking it to keep supervisor responsive.');
    AReader := nil;
  end;
end;

function TCoreSupervisor.BuildFailureMessage(const ABase, ACapturedOutput: string): string;
var
  critical: string;
begin
  result := ABase;
  if ACapturedOutput = '' then
    exit;

  critical := ExtractCriticalError(ACapturedOutput);
  if critical <> '' then
    result := result + sLineBreak + critical;
end;

procedure TCoreSupervisor.NotifyEvent(AEvent: TCoreEvent);
var
  handler: TCoreEventHandler;
begin
  if Terminated then
    exit;

  handler := FOnEvent;
  if not Assigned(handler) then
    exit;

  TThread.Queue(self,
    procedure
    begin
      handler(AEvent);
    end);
end;

procedure TCoreSupervisor.SetStateAndNotify(state: TCoreState; msg: string);
var
  event: TCoreEvent;
begin
  Log(trim(format('State: %s. %s', [STATE_NAMES[state], msg])));

  FState := state;

  event := Default (TCoreEvent);
  event.kind := cekState;
  event.state := state;
  event.msg := msg;

  NotifyEvent(event);
end;

procedure TCoreSupervisor.RequestStart(configJson: string);
var
  cmd: TCoreCommand;
begin
  cmd.kind := cmdStart;
  cmd.configJson := configJson;
  FQueue.PushItem(cmd);
end;

procedure TCoreSupervisor.RequestStop;
var
  cmd: TCoreCommand;
begin
  cmd.kind := cmdStop;
  FQueue.PushItem(cmd);
end;

function TCoreSupervisor.RequestSetSelectors(tasks: TSelectorTasks; requestId: NativeInt): boolean;
var
  cmd: TCoreCommand;
begin
  cmd.kind := cmdSetSelectors;
  cmd.selectorTasks := tasks;
  cmd.requestId := requestId;
  result := FQueue.PushItem(cmd) = wrSignaled;
end;

procedure TCoreSupervisor.HandleCommand(cmd: TCoreCommand);
begin
  Log(format('Command: %s.', [COMMAND_NAMES[cmd.kind]]));

  case cmd.kind of
    cmdStart:
      DoStart(cmd.configJson);
    cmdStop:
      DoStopGraceful;
    cmdSetSelectors:
      DoSetSelectors(cmd.selectorTasks, cmd.requestId);
  end;
end;

procedure TCoreSupervisor.DoStart(configJson: string);
  procedure SafeCloseHandle(var h: THandle);
  begin
    if (h <> 0) and (h <> INVALID_HANDLE_VALUE) then
      CloseHandle(h);
    h := 0;
  end;

  procedure WriteAllToHandle(h: THandle; const data: TBytes);
  var
    p: PByte;
    remain: DWORD;
    written: DWORD;
  begin
    if Length(data) = 0 then
      exit;

    p := @data[0];
    remain := DWORD(Length(data));

    while remain > 0 do
    begin
      written := 0;
      if not WriteFile(h, p^, remain, written, nil) then
        raise Exception.Create('WriteFile (stdin) failed.');

      if written = 0 then
        raise Exception.Create('WriteFile (stdin) wrote 0 bytes.');

      inc(p, written);
      dec(remain, written);
    end;
  end;

var
  exePath: string;
  jobHandle, processHandle, threadHandle: THandle;
  processId: DWORD;
  jobInfo: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
  si: TStartupInfo;
  pi: TProcessInformation;
  cmdLine, workDir: string;
  secAttr: TSecurityAttributes;
  stdinReadPipe, stdinWritePipe: THandle;
  outReadPipe, outWritePipe, readerPipe: THandle;
  reader: TPipeReader;
  configBytes: TBytes;
  resumeResult: DWORD;
  capturedOutput: string;
begin
  DoStopGraceful;

  SetStateAndNotify(csStarting);

  exePath := FExePath;

  jobHandle := 0;
  processHandle := 0;
  threadHandle := 0;

  stdinReadPipe := 0;
  stdinWritePipe := 0;
  outReadPipe := 0;
  outWritePipe := 0;
  reader := nil;

  try
    if not TFile.Exists(exePath) then
      raise Exception.Create('sing-box executable not found.');

    jobHandle := CreateJobObject(nil, nil);
    if jobHandle = 0 then
      raise Exception.Create('CreateJobObject failed.');

    ZeroMemory(@jobInfo, SizeOf(jobInfo));
    jobInfo.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    if not SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, @jobInfo, SizeOf(jobInfo)) then
      raise Exception.Create('SetInformationJobObject failed.');

    ZeroMemory(@secAttr, SizeOf(secAttr));
    secAttr.nLength := SizeOf(secAttr);
    secAttr.bInheritHandle := true;
    secAttr.lpSecurityDescriptor := nil;

    if not CreatePipe(stdinReadPipe, stdinWritePipe, @secAttr, 0) then
      raise Exception.Create('CreatePipe (stdin) failed.');

    if not SetHandleInformation(stdinWritePipe, HANDLE_FLAG_INHERIT, 0) then
      raise Exception.Create('SetHandleInformation (stdin) failed.');

    if not CreatePipe(outReadPipe, outWritePipe, @secAttr, 0) then
      raise Exception.Create('CreatePipe (output) failed.');

    if not SetHandleInformation(outReadPipe, HANDLE_FLAG_INHERIT, 0) then
      raise Exception.Create('SetHandleInformation (output) failed.');

    ZeroMemory(@si, SizeOf(si));
    ZeroMemory(@pi, SizeOf(pi));
    si.cb := SizeOf(si);
    si.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    si.wShowWindow := SW_HIDE;
    si.hStdInput := stdinReadPipe;
    si.hStdOutput := outWritePipe;
    si.hStdError := outWritePipe;

    cmdLine := format('"%s" --disable-color run -c stdin', [exePath]);
    workDir := ExtractFileDir(exePath);

    if not CreateProcess(nil, PChar(cmdLine), nil, nil, true, CREATE_NEW_CONSOLE or CREATE_SUSPENDED, nil,
      PChar(workDir), si, pi) then
      raise Exception.Create('CreateProcess failed.');

    processHandle := pi.hProcess;
    threadHandle := pi.hThread;
    processId := pi.dwProcessId;

    SafeCloseHandle(stdinReadPipe);
    SafeCloseHandle(outWritePipe);

    if not AssignProcessToJobObject(jobHandle, processHandle) then
      raise Exception.Create('AssignProcessToJobObject failed.');

    readerPipe := outReadPipe;
    outReadPipe := 0;
    reader := TPipeReader.Create(readerPipe);

    resumeResult := ResumeThread(threadHandle);
    SafeCloseHandle(threadHandle);
    if resumeResult = DWORD(-1) then
      raise Exception.Create('ResumeThread failed.');

    configBytes := TEncoding.UTF8.GetBytes(configJson);
    WriteAllToHandle(stdinWritePipe, configBytes);
    SafeCloseHandle(stdinWritePipe);
  except
    on E: Exception do
    begin
      if processHandle <> 0 then
        TerminateProcess(processHandle, 1);

      SafeCloseHandle(jobHandle);

      SafeCloseHandle(stdinReadPipe);
      SafeCloseHandle(stdinWritePipe);
      SafeCloseHandle(outWritePipe);

      DrainReader(reader, capturedOutput);

      SafeCloseHandle(outReadPipe);

      SafeCloseHandle(processHandle);
      SafeCloseHandle(threadHandle);

      SetStateAndNotify(csFailed, BuildFailureMessage(E.Message, capturedOutput));

      exit;
    end;
  end;

  FJobHandle := jobHandle;
  FProcessHandle := processHandle;
  FProcessId := processId;
  FOutputReader := reader;

  Log(format('Process created, PID: %d.', [processId]));
  SetStateAndNotify(csRunning);
  InitApiCheck;
end;

function TCoreSupervisor.SendCtrlCToConsole(processId: DWORD): boolean;
begin
  FreeConsole;
  if not AttachConsole(processId) then
    exit(false);
  try
    SetConsoleCtrlHandler(nil, true);
    try
      result := GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
      sleep(10);
    finally
      SetConsoleCtrlHandler(nil, false);
    end;
  finally
    FreeConsole;
  end;
end;

procedure TCoreSupervisor.DoStopGraceful;
var
  kill: boolean;
begin
  if FProcessHandle = 0 then
    exit;
  SetStateAndNotify(csStopping);

  kill := true;
  if SendCtrlCToConsole(FProcessId) then
  begin
    Log('Graceful shutdown signal sent.');
    if WaitForSingleObject(FProcessHandle, 10000) <> WAIT_TIMEOUT then
    begin
      kill := false;
      Log('Graceful shutdown complete.');
    end;
  end;

  if kill then
  begin
    Log('Graceful shutdown timeout, forcing termination.');
    TerminateProcess(FProcessHandle, 1);
    WaitForSingleObject(FProcessHandle, 1000);
  end;

  CleanupProcess;
  SetStateAndNotify(csStopped);
end;

procedure TCoreSupervisor.CheckProcessStatus;
begin
  if FProcessHandle = 0 then
    exit;

  if WaitForSingleObject(FProcessHandle, 0) <> WAIT_TIMEOUT then
  begin
    CleanupProcess;
    SetStateAndNotify(csFailed, BuildFailureMessage('sing-box process exited unexpectedly.', FLastCapturedOutput));
  end;
end;

procedure TCoreSupervisor.InitApiCheck;
const
  API_CHECK_DELAY = 500;
  API_CHECK_TIMEOUT = 60000;
var
  now: UInt64;
begin
  if not FCoreApiClient.IsConfigured then
  begin
    FApiCheckActive := false;
    exit;
  end;

  now := GetTickCount64;
  FApiCheckActive := true;
  FApiNextCheckTick := now + API_CHECK_DELAY;
  FApiDeadlineTick := now + API_CHECK_TIMEOUT;
end;

procedure TCoreSupervisor.CheckApiStatus;
const
  API_CHECK_INTERVAL = 500;
var
  now: UInt64;
  event: TCoreEvent;
begin
  if not FApiCheckActive then
    exit;

  if not IsProcessRunning then
  begin
    FApiCheckActive := false;
    exit;
  end;

  now := GetTickCount64;

  if now < FApiNextCheckTick then
    exit;

  if now >= FApiDeadlineTick then
  begin
    Log('API check timeout, stopping checks.');
    FApiCheckActive := false;
    exit;
  end;

  FApiNextCheckTick := now + API_CHECK_INTERVAL;

  if FCoreApiClient.CheckReady then
  begin
    Log('API ready.');
    FApiCheckActive := false;

    event := Default (TCoreEvent);
    event.kind := cekApiReady;
    NotifyEvent(event);
  end;
end;

procedure TCoreSupervisor.Log(const AMessage: string);
begin
  FLogger.Log('Core', AMessage);
end;

function TCoreSupervisor.IsProcessRunning: boolean;
begin
  result := FProcessHandle <> 0;
end;

procedure TCoreSupervisor.DoSetSelectors(tasks: TSelectorTasks; requestId: NativeInt);
const
  CONNECTIONS_FLUSH_TIMEOUT = 2000;
var
  task: TSelectorTask;
  event: TCoreEvent;
  hasError: boolean;
begin
  hasError := false;

  for task in tasks do
  begin
    try
      FCoreApiClient.SendClashApiRequest('PUT', '/proxies/' + task.name, '{"name":"' + task.value + '"}');
    except
      on E: Exception do
      begin
        hasError := true;
        Log(trim(format('Selector update failed for "%s". %s', [task.name, E.Message])));
      end;
    end;
  end;

  if hasError then
  begin
    event := Default (TCoreEvent);
    event.kind := cekError;
    event.msg := 'Selector update failed.';
    NotifyEvent(event);
  end;

  event := Default (TCoreEvent);
  event.kind := cekSelectorDone;
  event.requestId := requestId;
  NotifyEvent(event);

  try
    FCoreApiClient.SendClashApiRequest('DELETE', '/connections', '', CONNECTIONS_FLUSH_TIMEOUT);
  except
    on E: Exception do
      Log(trim('Connections flush failed. ' + E.Message));
  end;
end;

end.
