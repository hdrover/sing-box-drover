unit CoreSupervisor;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils,
  System.Generics.Collections, System.SyncObjs, Logger;

type
  TCoreState = (csStopped, csStarting, csRunning, csStopping, csFailed);

  TCoreCommandKind = (cmdNone, cmdStart, cmdStop);

  TCoreCommand = record
    kind: TCoreCommandKind;
    configPath: string;
  end;

  TCoreCommandQueue = TThreadedQueue<TCoreCommand>;

  TCoreStateEvent = procedure(state: TCoreState; msg: string) of object;

  TCoreSupervisor = class(TThread)
  private
    FLogger: TLogger;
    FQueue: TCoreCommandQueue;
    FOnStateChanged: TCoreStateEvent;
    FJobHandle: THandle;
    FProcessHandle: THandle;
    FProcessId: DWORD;
    FState: TCoreState;
    FExePath: string;

    procedure SetStateAndNotify(state: TCoreState; msg: string = '');
    procedure HandleCommand(cmd: TCoreCommand);
    procedure DoStart(configPath: string);
    function SendCtrlCToConsole(processId: DWORD): boolean;
    procedure DoStopGraceful;
    procedure CheckProcessStatus;
    procedure CleanupProcess;
    procedure Log(const AMessage: string);
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create(AExePath: string; ALogger: TLogger);
    destructor Destroy; override;

    procedure RequestStart(configPath: string);
    procedure RequestStop;

    property OnStateChanged: TCoreStateEvent read FOnStateChanged write FOnStateChanged;
    property state: TCoreState read FState;
  end;

implementation

const
  STATE_NAMES: array [TCoreState] of string = ('Stopped', 'Starting', 'Running', 'Stopping', 'Failed');
  COMMAND_NAMES: array [TCoreCommandKind] of string = ('None', 'Start', 'Stop');

constructor TCoreSupervisor.Create(AExePath: string; ALogger: TLogger);
begin
  FLogger := ALogger;
  FQueue := TCoreCommandQueue.Create(10, 200, 200);
  FJobHandle := 0;
  FProcessHandle := 0;
  FProcessId := 0;
  FState := csStopped;
  FExePath := AExePath;

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

procedure TCoreSupervisor.SetStateAndNotify(state: TCoreState; msg: string);
var
  handler: TCoreStateEvent;
begin
  Log(Trim(Format('State: %s. %s', [STATE_NAMES[state], msg])));

  FState := state;

  if Terminated then
    exit;

  handler := FOnStateChanged;
  if not Assigned(handler) then
    exit;

  TThread.Queue(self,
    procedure
    begin
      handler(state, msg);
    end);
end;

procedure TCoreSupervisor.RequestStart(configPath: string);
var
  cmd: TCoreCommand;
begin
  cmd.kind := cmdStart;
  cmd.configPath := configPath;
  FQueue.PushItem(cmd);
end;

procedure TCoreSupervisor.RequestStop;
var
  cmd: TCoreCommand;
begin
  cmd.kind := cmdStop;
  FQueue.PushItem(cmd);
end;

procedure TCoreSupervisor.HandleCommand(cmd: TCoreCommand);
begin
  Log(Format('Command: %s.', [COMMAND_NAMES[cmd.kind]]));

  case cmd.kind of
    cmdStart:
      DoStart(cmd.configPath);
    cmdStop:
      DoStopGraceful;
  end;
end;

procedure TCoreSupervisor.DoStart(configPath: string);
var
  exePath: string;
  jobHandle: THandle;
  processHandle: THandle;
  processId: DWORD;
  jobInfo: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
  si: TStartupInfo;
  pi: TProcessInformation;
  cmdLine, workDir: string;
begin
  DoStopGraceful;

  SetStateAndNotify(csStarting);

  exePath := FExePath;

  jobHandle := 0;
  processHandle := 0;

  try
    if not TFile.Exists(exePath) then
      raise Exception.Create('sing-box executable not found.');

    if not TFile.Exists(configPath) then
      raise Exception.Create('Configuration file not found.');

    jobHandle := CreateJobObject(nil, nil);
    if jobHandle = 0 then
      raise Exception.Create('CreateJobObject failed.');

    ZeroMemory(@jobInfo, SizeOf(jobInfo));
    jobInfo.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    if not SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, @jobInfo, SizeOf(jobInfo)) then
      raise Exception.Create('SetInformationJobObject failed.');

    ZeroMemory(@si, SizeOf(si));
    ZeroMemory(@pi, SizeOf(pi));
    si.cb := SizeOf(si);
    si.dwFlags := STARTF_USESHOWWINDOW;
    si.wShowWindow := SW_HIDE;

    cmdLine := Format('"%s" run -c "%s"', [exePath, configPath]);
    workDir := ExtractFileDir(exePath);

    if not CreateProcess(nil, PChar(cmdLine), nil, nil, false, CREATE_NEW_CONSOLE, nil, PChar(workDir), si, pi) then
      raise Exception.Create('CreateProcess failed.');

    processHandle := pi.hProcess;
    processId := pi.dwProcessId;
    CloseHandle(pi.hThread);

    if not AssignProcessToJobObject(jobHandle, processHandle) then
    begin
      TerminateProcess(processHandle, 1);
      raise Exception.Create('AssignProcessToJobObject failed.');
    end;

    FJobHandle := jobHandle;
    FProcessHandle := processHandle;
    FProcessId := processId;

    Log(Format('Process created, PID: %d.', [processId]));

    // TODO Implement proper API readiness check. Sleep is a temporary workaround.
    sleep(1000);

    SetStateAndNotify(csRunning);
  except
    on E: Exception do
    begin
      if processHandle <> 0 then
        CloseHandle(processHandle);
      if jobHandle <> 0 then
        CloseHandle(jobHandle);

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
    result := GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
    sleep(10);
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

procedure TCoreSupervisor.Log(const AMessage: string);
begin
  FLogger.Log('[Core] ' + AMessage);
end;

end.
