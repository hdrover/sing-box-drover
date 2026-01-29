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

  TCoreEventKind = (cekState, cekError, cekApiReady);

  TCoreEvent = record
    kind: TCoreEventKind;
    state: TCoreState;
    msg: string;
  end;

  TCoreCommandKind = (cmdNone, cmdStart, cmdStop, cmdSetSelectors);

  TCoreCommand = record
    kind: TCoreCommandKind;
    configJson: string;
    selectorTasks: TSelectorTasks;
  end;

  TCoreCommandQueue = TThreadedQueue<TCoreCommand>;

  TCoreEventHandler = procedure(event: TCoreEvent) of object;

  TCoreSupervisor = class(TThread)
  private
    FLogger: TLogger;
    FQueue: TCoreCommandQueue;
    FOnEvent: TCoreEventHandler;
    FJobHandle: THandle;
    FProcessHandle: THandle;
    FProcessId: DWORD;
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
    procedure DoSetSelectors(tasks: TSelectorTasks);
    procedure CheckProcessStatus;
    procedure InitApiCheck;
    procedure CheckApiStatus;
    procedure CleanupProcess;
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
    procedure RequestSetSelectors(tasks: TSelectorTasks);

    property OnEvent: TCoreEventHandler read FOnEvent write FOnEvent;
    property state: TCoreState read FState;
  end;

implementation

const
  STATE_NAMES: array [TCoreState] of string = ('Stopped', 'Starting', 'Running', 'Stopping', 'Failed');
  COMMAND_NAMES: array [TCoreCommandKind] of string = ('None', 'Start', 'Stop', 'SetSelectors');

constructor TCoreSupervisor.Create(AExePath: string; ALogger: TLogger; AClashApiConfig: TClashApiConfig);
begin
  FLogger := ALogger;
  FQueue := TCoreCommandQueue.Create(10, 200, 200);
  FCoreApiClient := TCoreApiClient.Create(AClashApiConfig, ALogger);
  FJobHandle := 0;
  FProcessHandle := 0;
  FProcessId := 0;
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
  if FProcessHandle <> 0 then
  begin
    CloseHandle(FProcessHandle);
    FProcessHandle := 0;
  end;

  if FJobHandle <> 0 then
  begin
    CloseHandle(FJobHandle);
    FJobHandle := 0;
  end;

  FProcessId := 0;
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
  Log(Trim(Format('State: %s. %s', [STATE_NAMES[state], msg])));

  FState := state;

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

procedure TCoreSupervisor.RequestSetSelectors(tasks: TSelectorTasks);
var
  cmd: TCoreCommand;
begin
  cmd.kind := cmdSetSelectors;
  cmd.selectorTasks := tasks;
  FQueue.PushItem(cmd);
end;

procedure TCoreSupervisor.HandleCommand(cmd: TCoreCommand);
begin
  Log(Format('Command: %s.', [COMMAND_NAMES[cmd.kind]]));

  case cmd.kind of
    cmdStart:
      DoStart(cmd.configJson);
    cmdStop:
      DoStopGraceful;
    cmdSetSelectors:
      DoSetSelectors(cmd.selectorTasks);
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
  hNullOut: THandle;
  configBytes: TBytes;
  resumeResult: DWORD;
begin
  DoStopGraceful;

  SetStateAndNotify(csStarting);

  exePath := FExePath;

  jobHandle := 0;
  processHandle := 0;
  threadHandle := 0;

  stdinReadPipe := 0;
  stdinWritePipe := 0;
  hNullOut := 0;

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
      raise Exception.Create('CreatePipe failed.');

    if not SetHandleInformation(stdinWritePipe, HANDLE_FLAG_INHERIT, 0) then
      raise Exception.Create('SetHandleInformation failed.');

    hNullOut := CreateFile('NUL', GENERIC_WRITE, FILE_SHARE_READ or FILE_SHARE_WRITE, @secAttr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL, 0);
    if hNullOut = INVALID_HANDLE_VALUE then
      raise Exception.Create('CreateFile (NUL) failed.');

    ZeroMemory(@si, SizeOf(si));
    ZeroMemory(@pi, SizeOf(pi));
    si.cb := SizeOf(si);
    si.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
    si.wShowWindow := SW_HIDE;
    si.hStdInput := stdinReadPipe;
    si.hStdOutput := hNullOut;
    si.hStdError := hNullOut;

    cmdLine := Format('"%s" run -c stdin', [exePath]);
    workDir := ExtractFileDir(exePath);

    if not CreateProcess(nil, PChar(cmdLine), nil, nil, true, CREATE_NEW_CONSOLE or CREATE_SUSPENDED, nil,
      PChar(workDir), si, pi) then
      raise Exception.Create('CreateProcess failed.');

    processHandle := pi.hProcess;
    threadHandle := pi.hThread;
    processId := pi.dwProcessId;

    SafeCloseHandle(stdinReadPipe);
    SafeCloseHandle(hNullOut);

    if not AssignProcessToJobObject(jobHandle, processHandle) then
      raise Exception.Create('AssignProcessToJobObject failed.');

    resumeResult := ResumeThread(threadHandle);
    SafeCloseHandle(threadHandle);
    if resumeResult = DWORD(-1) then
      raise Exception.Create('ResumeThread failed.');

    configBytes := TEncoding.UTF8.GetBytes(configJson);
    WriteAllToHandle(stdinWritePipe, configBytes);
    SafeCloseHandle(stdinWritePipe);

    FJobHandle := jobHandle;
    FProcessHandle := processHandle;
    FProcessId := processId;

    Log(Format('Process created, PID: %d.', [processId]));

    SetStateAndNotify(csRunning);
    InitApiCheck;
  except
    on E: Exception do
    begin
      if processHandle <> 0 then
        TerminateProcess(processHandle, 1);

      SafeCloseHandle(stdinReadPipe);
      SafeCloseHandle(stdinWritePipe);
      SafeCloseHandle(hNullOut);
      SafeCloseHandle(processHandle);
      SafeCloseHandle(threadHandle);
      SafeCloseHandle(jobHandle);

      SetStateAndNotify(csFailed, E.Message);
    end;
  end;
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
    SetStateAndNotify(csFailed, 'sing-box process exited unexpectedly.');
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

    event.kind := cekApiReady;
    event.msg := '';
    NotifyEvent(event);
  end;
end;

procedure TCoreSupervisor.Log(const AMessage: string);
begin
  FLogger.Log('[Core] ' + AMessage);
end;

function TCoreSupervisor.IsProcessRunning: boolean;
begin
  result := FProcessHandle <> 0;
end;

procedure TCoreSupervisor.DoSetSelectors(tasks: TSelectorTasks);
var
  task: TSelectorTask;
  event: TCoreEvent;
  s: string;
begin
  try
    for task in tasks do
    begin
      FCoreApiClient.SendClashApiRequest('PUT', '/proxies/' + task.name, '{"name":"' + task.value + '"}');
    end;

    FCoreApiClient.SendClashApiRequest('DELETE', '/connections', '');
  except
    on E: Exception do
    begin
      s := 'Selector update failed.';
      Log(s);

      event.kind := cekError;
      event.msg := s;
      NotifyEvent(event);
    end;
  end;
end;

end.
