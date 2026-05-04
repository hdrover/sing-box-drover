unit Drover;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, SystemProxy,
  System.JSON, System.IOUtils, System.Generics.Collections, Options,
  CoreSupervisor, Logger, AppElevation, AppArgs, SingBoxConfig, SingBoxCli,
  ConfigReader, ConfigUpdater, AppState;

const
  WM_DROVER_CAN_CLOSE = WM_APP + 501;
  STATE_FILENAME = 'sing-box-drover.state.json';

type
  TDroverEventKind = (dekError, dekRunning, dekCoreEvent);

  TDroverEvent = record
    kind: TDroverEventKind;
    msg: string;
    coreEvent: TCoreEvent;
  end;

  TDroverEventHandler = procedure(event: TDroverEvent) of object;

  TDrover = class
  private
    FSupervisor: TCoreSupervisor;
    FConfigUpdater: TConfigUpdater;
    FSingBoxCli: TSingBoxCli;
    FOnEvent: TDroverEventHandler;
    FLogger: TLogger;
    FNotifyHandle: HWND;
    FShutdownRequested: boolean;
    FShutdownCompleted: boolean;
    FSupervisorTerminateSeen: boolean;
    FConfigUpdaterTerminateSeen: boolean;
    FDestroying: boolean;
    FPendingEvents: TList<TDroverEvent>;
    FIsElevated: boolean;
    FIsTunActive: boolean;
    FSelectors: TConfigSelectors;
    FAppState: TAppState;

    procedure HandleCoreEvent(event: TCoreEvent);
    procedure HandleWorkerTerminated(sender: TObject);
    procedure PostCanClose;
    function IsWorkerFinished(AWorker: TThread; ATerminateSeen: boolean): boolean;
    function BackgroundWorkersFinished: boolean;
    procedure RequestShutdownWorkers;
    procedure TryCompleteShutdown;
    procedure NotifyEvent(kind: TDroverEventKind; msg: string = ''); overload;
    procedure NotifyEvent(const event: TDroverEvent); overload;
    procedure ForwardCoreEvent(const event: TCoreEvent);
    procedure SetOnEvent(value: TDroverEventHandler);
    procedure FlushPendingEvents;
    procedure DestroyConfigUpdater;
    procedure DestroySupervisor;
    procedure ApplyPersistedSelectors;
    procedure Log(const AMessage: string);
  public
    configSource: TConfigSource;
    sbConfig: TSingBoxConfig;
    FOptions: TDroverOptions;
    currentProcessDir: string;

    constructor Create(AFlags: TAppFlags);
    destructor Destroy; override;

    procedure ResetSelectors;
    procedure PersistSelectors;
    procedure PersistRuntimeState;
    function EditSelector(selectorIdx, outboundIdx: integer; requestId: NativeInt): boolean;
    function EnableSystemProxy: boolean;
    function DisableSystemProxy: boolean;
    function Shutdown: boolean;
    procedure StartCore(useTun: boolean);
    function CanUseTun: boolean;

    property Options: TDroverOptions read FOptions;
    property OnEvent: TDroverEventHandler read FOnEvent write SetOnEvent;
    property NotifyHandle: HWND read FNotifyHandle write FNotifyHandle;
    property IsTunActive: boolean read FIsTunActive;
    property Selectors: TConfigSelectors read FSelectors;
  end;

implementation

constructor TDrover.Create(AFlags: TAppFlags);
var
  corePath: string;
begin
  FPendingEvents := TList<TDroverEvent>.Create;
  FConfigUpdater := nil;

  currentProcessDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));

  FOptions := TDroverOptions.Load(currentProcessDir + OPTIONS_FILENAME);

  FLogger := TLogger.Create(FOptions.logFile);

  configSource := ConfigReader.ReadConfigSource(FOptions.sbConfigFile);
  sbConfig := ConfigReader.ReadSingBoxConfig(configSource.jsonText);
  ConfigReader.CheckSingBoxConfig(sbConfig);
  FSelectors := sbConfig.Selectors;

  FAppState := TAppState.Create(currentProcessDir + STATE_FILENAME);
  if (afRestart in AFlags) or FOptions.selectorPersist then
    ApplyPersistedSelectors;

  FIsElevated := AppElevation.IsProcessElevated;

  corePath := FOptions.sbDir + 'sing-box.exe';
  if not TFile.Exists(corePath) then
    raise Exception.Create('sing-box executable not found.');

  FSingBoxCli := TSingBoxCli.Create(corePath, FLogger);

  FSupervisor := TCoreSupervisor.Create(corePath, FLogger, sbConfig.clashApi);
  FSupervisor.OnEvent := HandleCoreEvent;
  FSupervisor.OnTerminate := HandleWorkerTerminated;
  StartCore(CanUseTun and ((FOptions.tunStartMode = tsmOn) or (afTun in AFlags)));

  if configSource.isBpf and configSource.bpfProfile.isRemote and configSource.bpfProfile.autoUpdate then
  begin
    FConfigUpdater := TConfigUpdater.Create(configSource, FSingBoxCli, FLogger);
    FConfigUpdater.OnTerminate := HandleWorkerTerminated;
  end;
end;

destructor TDrover.Destroy;
begin
  FDestroying := true;

  DestroyConfigUpdater;
  DestroySupervisor;

  FreeAndNil(FSingBoxCli);
  FreeAndNil(FAppState);
  FreeAndNil(FPendingEvents);
  FreeAndNil(FLogger);

  inherited;
end;

procedure TDrover.StartCore(useTun: boolean);
var
  configJson: string;
begin
  if not CanUseTun then
    useTun := false;

  FIsTunActive := useTun;

  if useTun then
    configJson := sbConfig.jsonWithTun
  else
    configJson := sbConfig.jsonWithoutTun;

  FSupervisor.RequestStart(configJson);
end;

function TDrover.CanUseTun: boolean;
begin
  result := sbConfig.hasTunInbound and FIsElevated;
end;

procedure TDrover.SetOnEvent(value: TDroverEventHandler);
begin
  FOnEvent := value;
  if Assigned(FOnEvent) then
    FlushPendingEvents;
end;

procedure TDrover.NotifyEvent(kind: TDroverEventKind; msg: string = '');
var
  ev: TDroverEvent;
begin
  ev := Default (TDroverEvent);
  ev.kind := kind;
  ev.msg := msg;

  NotifyEvent(ev);
end;

procedure TDrover.NotifyEvent(const event: TDroverEvent);
begin
  if Assigned(FOnEvent) then
    FOnEvent(event)
  else
    FPendingEvents.Add(event);
end;

procedure TDrover.ForwardCoreEvent(const event: TCoreEvent);
var
  ev: TDroverEvent;
begin
  ev := Default (TDroverEvent);
  ev.kind := dekCoreEvent;
  ev.coreEvent := event;
  NotifyEvent(ev);
end;

procedure TDrover.FlushPendingEvents;
var
  ev: TDroverEvent;
begin
  for ev in FPendingEvents do
    FOnEvent(ev);
  FPendingEvents.Clear;
end;

procedure TDrover.DestroyConfigUpdater;
begin
  if not Assigned(FConfigUpdater) then
    exit;

  FConfigUpdater.OnTerminate := nil;

  if not FConfigUpdater.Finished then
  begin
    FConfigUpdater.Terminate;
    FConfigUpdater.WaitFor;
  end;

  FreeAndNil(FConfigUpdater);
end;

procedure TDrover.DestroySupervisor;
begin
  if not Assigned(FSupervisor) then
    exit;

  FSupervisor.OnEvent := nil;
  FSupervisor.OnTerminate := nil;

  if not FSupervisor.Finished then
  begin
    FSupervisor.Terminate;
    TThread.RemoveQueuedEvents(FSupervisor);
    FSupervisor.WaitFor;
    TThread.RemoveQueuedEvents(FSupervisor);
  end;

  FreeAndNil(FSupervisor);
end;

procedure TDrover.HandleCoreEvent(event: TCoreEvent);
begin
  if FDestroying or FShutdownRequested then
    exit;

  case event.kind of
    cekState:
      begin
        case event.state of
          csRunning:
            NotifyEvent(dekRunning, '');

          csFailed:
            NotifyEvent(dekError, event.msg);
        end;
      end;

    cekError:
      NotifyEvent(dekError, event.msg);

    cekApiReady:
      ResetSelectors;

    cekSelectorDone:
      ForwardCoreEvent(event);
  end;

end;

procedure TDrover.HandleWorkerTerminated(sender: TObject);
begin
  if sender = FSupervisor then
    FSupervisorTerminateSeen := true
  else if sender = FConfigUpdater then
    FConfigUpdaterTerminateSeen := true;

  if FDestroying or (not FShutdownRequested) or FShutdownCompleted then
    exit;

  TryCompleteShutdown;
  if FShutdownCompleted then
    PostCanClose;
end;

procedure TDrover.ApplyPersistedSelectors;
var
  selectorI, outboundI: integer;
  selector: ^TConfigSelector;
  savedValue: string;
begin
  for selectorI := low(FSelectors) to high(FSelectors) do
  begin
    selector := @FSelectors[selectorI];
    if not FAppState.GetSelector(selector.name, savedValue) then
      continue;
    for outboundI := low(selector.outbounds) to high(selector.outbounds) do
    begin
      if selector.outbounds[outboundI] = savedValue then
      begin
        selector.defaultIndex := outboundI;
        break;
      end;
    end;
  end;
end;

procedure TDrover.ResetSelectors;
var
  selector: TConfigSelector;
  outboundI: integer;
  task: TSelectorTask;
  tasks: TSelectorTasks;
  taskI: integer;
begin
  SetLength(tasks, length(FSelectors));
  taskI := 0;

  for selector in FSelectors do
  begin
    outboundI := selector.defaultIndex;
    if (outboundI >= low(selector.outbounds)) and (outboundI <= high(selector.outbounds)) then
    begin
      task.name := selector.name;
      task.value := selector.outbounds[outboundI];
      tasks[taskI] := task;
      inc(taskI);
    end;
  end;

  if taskI < 1 then
    exit;

  SetLength(tasks, taskI);

  FSupervisor.RequestSetSelectors(tasks, 0);
end;

procedure TDrover.PersistSelectors;
var
  values: TDictionary<string, string>;
  scope: TArray<string>;
  i, idx: integer;
  selector: ^TConfigSelector;
begin
  values := TDictionary<string, string>.Create;
  try
    SetLength(scope, length(FSelectors));
    for i := low(FSelectors) to high(FSelectors) do
    begin
      selector := @FSelectors[i];
      scope[i] := selector.name;
      idx := selector.defaultIndex;
      if (idx >= low(selector.outbounds)) and (idx <= high(selector.outbounds)) then
        values.AddOrSetValue(selector.name, selector.outbounds[idx]);
    end;

    try
      FAppState.SyncSelectors(values, scope);
    except
      on E: Exception do
        Log(trim(format('Failed to persist selector state. %s', [E.Message])));
    end;
  finally
    values.Free;
  end;
end;

procedure TDrover.PersistRuntimeState;
begin
  PersistSelectors;
end;

function TDrover.EditSelector(selectorIdx, outboundIdx: integer; requestId: NativeInt): boolean;
var
  selector: TConfigSelector;
  task: TSelectorTask;
begin
  result := false;

  if (selectorIdx < low(FSelectors)) or (selectorIdx > high(FSelectors)) then
    exit;

  selector := FSelectors[selectorIdx];
  if (outboundIdx < low(selector.outbounds)) or (outboundIdx > high(selector.outbounds)) then
    exit;

  FSelectors[selectorIdx].defaultIndex := outboundIdx;
  PersistSelectors;

  task.name := selector.name;
  task.value := selector.outbounds[outboundIdx];

  result := FSupervisor.RequestSetSelectors([task], requestId);
end;

function TDrover.EnableSystemProxy: boolean;
begin
  result := SystemProxy.EnableSystemProxy(sbConfig.proxyHost, sbConfig.proxyPort);
end;

function TDrover.DisableSystemProxy: boolean;
begin
  result := SystemProxy.DisableSystemProxy;
end;

function TDrover.Shutdown: boolean;
begin
  if FShutdownCompleted then
    exit(true);

  if not FShutdownRequested then
  begin
    FShutdownRequested := true;
    RequestShutdownWorkers;
  end;

  TryCompleteShutdown;
  result := FShutdownCompleted;
end;

procedure TDrover.TryCompleteShutdown;
begin
  if FShutdownCompleted or (not BackgroundWorkersFinished) then
    exit;

  FShutdownCompleted := true;
  if Assigned(FLogger) then
    FLogger.Close;
end;

function TDrover.IsWorkerFinished(AWorker: TThread; ATerminateSeen: boolean): boolean;
begin
  result := (not Assigned(AWorker)) or ATerminateSeen or AWorker.Finished;
end;

function TDrover.BackgroundWorkersFinished: boolean;
begin
  result := IsWorkerFinished(FSupervisor, FSupervisorTerminateSeen) and
    IsWorkerFinished(FConfigUpdater, FConfigUpdaterTerminateSeen);
end;

procedure TDrover.RequestShutdownWorkers;
begin
  if Assigned(FConfigUpdater) and not FConfigUpdater.Finished then
    FConfigUpdater.Terminate;

  if Assigned(FSupervisor) and not FSupervisor.Finished then
  begin
    FSupervisor.OnEvent := nil;
    FSupervisor.Terminate;
    TThread.RemoveQueuedEvents(FSupervisor);
  end;
end;

procedure TDrover.PostCanClose;
begin
  if (FNotifyHandle <> 0) and IsWindow(FNotifyHandle) then
    PostMessage(FNotifyHandle, WM_DROVER_CAN_CLOSE, 0, 0);
end;

procedure TDrover.Log(const AMessage: string);
begin
  FLogger.Log('Drover', AMessage);
end;

end.
