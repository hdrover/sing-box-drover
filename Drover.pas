unit Drover;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, SystemProxy,
  System.JSON, System.IOUtils, System.Generics.Collections, Options,
  CoreSupervisor, Logger, AppElevation, AppArgs, SingBoxConfig, ConfigReader;

const
  WM_DROVER_CAN_CLOSE = WM_APP + 501;

type
  TDroverEventKind = (dekError, dekRunning);

  TDroverEvent = record
    kind: TDroverEventKind;
    msg: string;
  end;

  TDroverEventHandler = procedure(event: TDroverEvent) of object;

  TDrover = class
  private
    FSupervisor: TCoreSupervisor;
    FOnEvent: TDroverEventHandler;
    FLogger: TLogger;
    FNotifyHandle: HWND;
    FShutdownRequested: boolean;
    FShutdownComplete: boolean;
    FDestroying: boolean;
    FPendingEvents: TList<TDroverEvent>;
    FIsElevated: boolean;
    FIsTunActive: boolean;
    FSelectors: TConfigSelectors;

    procedure HandleCoreEvent(event: TCoreEvent);
    procedure SupervisorTerminated(sender: TObject);
    procedure PostCanClose;
    procedure FinalizeShutdown;
    procedure NotifyEvent(kind: TDroverEventKind; msg: string = '');
    procedure SetOnEvent(value: TDroverEventHandler);
    procedure FlushPendingEvents;
  public
    configSource: TConfigSource;
    sbConfig: TSingBoxConfig;
    FOptions: TDroverOptions;
    currentProcessDir: string;

    constructor Create(AFlags: TAppFlags);
    destructor Destroy; override;

    procedure ResetSelectors;
    procedure EditSelector(selectorIdx, outboundIdx: integer);
    function EnableSystemProxy: boolean;
    function DisableSystemProxy: boolean;
    function Shutdown: boolean;
    procedure StartCore(useTun: boolean);
    function CanUseTun: boolean;

    property Options: TDroverOptions read FOptions;
    property OnEvent: TDroverEventHandler read FOnEvent write SetOnEvent;
    property NotifyHandle: HWND read FNotifyHandle write FNotifyHandle;
    property IsElevated: boolean read FIsElevated;
    property IsTunActive: boolean read FIsTunActive;
    property Selectors: TConfigSelectors read FSelectors;
  end;

implementation

constructor TDrover.Create(AFlags: TAppFlags);
var
  corePath: string;
begin
  FPendingEvents := TList<TDroverEvent>.Create;

  currentProcessDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));

  FOptions := TDroverOptions.Load(currentProcessDir + OPTIONS_FILENAME);

  FLogger := TLogger.Create(FOptions.logFile);

  configSource := ConfigReader.ReadConfigSource(FOptions.sbConfigFile);
  sbConfig := ConfigReader.ReadSingBoxConfig(configSource.jsonText);
  ConfigReader.CheckSingBoxConfig(sbConfig);
  FSelectors := sbConfig.Selectors;

  FIsElevated := AppElevation.IsProcessElevated;

  corePath := FOptions.sbDir + 'sing-box.exe';
  if not TFile.Exists(corePath) then
    raise Exception.Create('sing-box executable not found.');

  FSupervisor := TCoreSupervisor.Create(corePath, FLogger, sbConfig.clashApi);
  FSupervisor.OnEvent := HandleCoreEvent;
  FSupervisor.OnTerminate := SupervisorTerminated;
  StartCore(CanUseTun and ((FOptions.tunStartMode = tsmOn) or (afTun in AFlags)));
end;

destructor TDrover.Destroy;
begin
  FDestroying := true;

  if Assigned(FSupervisor) then
  begin
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
  ev.kind := kind;
  ev.msg := msg;

  if Assigned(FOnEvent) then
    FOnEvent(ev)
  else
    FPendingEvents.Add(ev);
end;

procedure TDrover.FlushPendingEvents;
var
  ev: TDroverEvent;
begin
  for ev in FPendingEvents do
    FOnEvent(ev);
  FPendingEvents.Clear;
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
  end;

end;

procedure TDrover.SupervisorTerminated(sender: TObject);
begin
  if FDestroying then
    exit;

  if FShutdownRequested then
  begin
    FinalizeShutdown;
    PostCanClose;
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
  SetLength(tasks, Length(FSelectors));
  taskI := 0;

  for selector in FSelectors do
  begin
    outboundI := selector.defaultIndex;
    if (outboundI >= Low(selector.outbounds)) and (outboundI <= High(selector.outbounds)) then
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

  FSupervisor.RequestSetSelectors(tasks);
end;

procedure TDrover.EditSelector(selectorIdx, outboundIdx: integer);
var
  selector: TConfigSelector;
  task: TSelectorTask;
begin
  if (selectorIdx < Low(FSelectors)) or (selectorIdx > High(FSelectors)) then
    exit;

  selector := FSelectors[selectorIdx];
  if (outboundIdx < Low(selector.outbounds)) or (outboundIdx > High(selector.outbounds)) then
    exit;

  FSelectors[selectorIdx].defaultIndex := outboundIdx;

  task.name := selector.name;
  task.value := selector.outbounds[outboundIdx];

  FSupervisor.RequestSetSelectors([task]);
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
  if FShutdownComplete then
    exit(true);

  if (not Assigned(FSupervisor)) or FSupervisor.Finished then
  begin
    FinalizeShutdown;
    exit(true);
  end;

  if not FShutdownRequested then
  begin
    FShutdownRequested := true;
    FSupervisor.OnEvent := nil;
    FSupervisor.Terminate;
    TThread.RemoveQueuedEvents(FSupervisor);
  end;

  result := false;
end;

procedure TDrover.FinalizeShutdown;
begin
  if FShutdownComplete then
    exit;
  FShutdownComplete := true;
  if Assigned(FLogger) then
    FLogger.Close;
end;

procedure TDrover.PostCanClose;
begin
  if (FNotifyHandle <> 0) and IsWindow(FNotifyHandle) then
    PostMessage(FNotifyHandle, WM_DROVER_CAN_CLOSE, 0, 0);
end;

end.
