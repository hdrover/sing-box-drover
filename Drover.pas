unit Drover;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, SystemProxy,
  System.JSON, System.IOUtils, System.Generics.Collections, Options, JsonUtils,
  CoreSupervisor, Logger, AppElevation, AppArgs, SingBoxConfig, SingBoxBpf;

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
    procedure RemoveTunInbounds(rootObj: TJSONObject);
    procedure CreateDefaultClashApi(rootObj: TJSONObject; var config: TSingBoxConfig);
  public
    configSource: TConfigSource;
    sbConfig: TSingBoxConfig;
    FOptions: TDroverOptions;
    currentProcessDir: string;

    constructor Create(AFlags: TAppFlags);
    destructor Destroy; override;

    function ReadConfigSource(configPath: string): TConfigSource;
    function ReadSingBoxConfig(const configSource: TConfigSource): TSingBoxConfig;
    procedure CheckSingBoxConfig(cfg: TSingBoxConfig);
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

  configSource := ReadConfigSource(FOptions.sbConfigFile);
  sbConfig := ReadSingBoxConfig(configSource);
  CheckSingBoxConfig(sbConfig);
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

procedure TDrover.RemoveTunInbounds(rootObj: TJSONObject);
var
  i: integer;
  inboundsArr: TJSONArray;
  inboundVal: TJSONValue;
  inboundObj: TJSONObject;
  inboundType: string;
begin
  if not rootObj.TryGetValue('inbounds', inboundsArr) then
    exit;

  for i := inboundsArr.Count - 1 downto 0 do
  begin
    inboundVal := inboundsArr.Items[i];
    if not(inboundVal is TJSONObject) then
      continue;
    inboundObj := inboundVal as TJSONObject;
    if inboundObj.TryGetValue('type', inboundType) and SameText(inboundType, 'tun') then
      inboundsArr.Remove(i).Free;
  end;
end;

procedure TDrover.CreateDefaultClashApi(rootObj: TJSONObject; var config: TSingBoxConfig);
var
  controller, secret: string;
  experimentalObj, clashApiObj: TJSONObject;
  val: TJSONValue;
begin
  if rootObj.TryGetValue('experimental', val) then
  begin
    if not(val is TJSONObject) then
      exit;
    experimentalObj := val as TJSONObject;
  end
  else
  begin
    experimentalObj := TJSONObject.Create;
    rootObj.AddPair('experimental', experimentalObj);
  end;

  if experimentalObj.TryGetValue('clash_api', val) then
    exit;

  controller := '127.0.0.1:9090';
  secret := TGUID.NewGuid.ToString;

  clashApiObj := TJSONObject.Create;
  clashApiObj.AddPair('external_controller', controller);
  clashApiObj.AddPair('secret', secret);
  experimentalObj.AddPair('clash_api', clashApiObj);

  config.clashApi.externalController := controller;
  config.clashApi.secret := secret;
end;

function TDrover.ReadConfigSource(configPath: string): TConfigSource;
var
  configBytes: TBytes;

  function Utf8TextFromBytes(const data: TBytes): string;
  var
    offset: integer;
  begin
    offset := 0;
    if (Length(data) >= 3) and (data[0] = $EF) and (data[1] = $BB) and (data[2] = $BF) then
      offset := 3;

    result := TEncoding.UTF8.GetString(data, offset, Length(data) - offset);
  end;

begin
  result := Default (TConfigSource);
  result.filePath := configPath;

  if not TFile.Exists(configPath) then
    raise Exception.Create('Configuration file not found.');

  try
    configBytes := TFile.ReadAllBytes(configPath);
  except
    raise Exception.Create('Failed to read configuration file.');
  end;

  if LooksLikeBpfProfileData(configBytes) then
  begin
    result.format := csfBpf;
    result.bpfProfile := DecodeBpfProfile(configBytes);
    result.jsonText := result.bpfProfile.configJson;
  end
  else
  begin
    result.format := csfJson;
    result.jsonText := Utf8TextFromBytes(configBytes);
  end;
end;

function TDrover.ReadSingBoxConfig(const configSource: TConfigSource): TSingBoxConfig;
var
  jsonText: string;
  rootValue: TJSONValue;
  rootObj: TJSONObject;
  outboundName: string;
  itemsArr: TJSONArray;
  outboundI: integer;
  itemVal: TJSONValue;
  itemObj, obj: TJSONObject;
  sel: TConfigSelector;
  outboundsArr: TJSONArray;
  selectorList: TList<TConfigSelector>;
  inboundType: string;

  function getStr(const obj: TJSONObject; const name: string; const ADefault: string = ''): string;
  begin
    if not obj.TryGetValue(name, result) then
      result := ADefault;
  end;

begin
  result := Default (TSingBoxConfig);

  jsonText := NormalizeJson(configSource.jsonText);
  rootValue := TJSONObject.ParseJSONValue(jsonText);
  if rootValue = nil then
    raise Exception.Create('Configuration file is corrupted or contains invalid JSON.');

  try
    if not(rootValue is TJSONObject) then
      raise Exception.Create('Invalid JSON.');

    rootObj := rootValue as TJSONObject;

    if rootObj.TryGetValue('inbounds', itemsArr) then
    begin
      for itemVal in itemsArr do
      begin
        if not(itemVal is TJSONObject) then
          continue;
        itemObj := itemVal as TJSONObject;

        inboundType := getStr(itemObj, 'type');

        if SameText(inboundType, 'mixed') then
        begin
          result.proxyHost := getStr(itemObj, 'listen');
          result.proxyPort := StrToIntDef(getStr(itemObj, 'listen_port'), 0);
        end;

        if SameText(inboundType, 'tun') then
          result.hasTunInbound := true;
      end;
    end;

    if rootObj.TryGetValue('outbounds', itemsArr) then
    begin
      selectorList := TList<TConfigSelector>.Create;
      try
        for itemVal in itemsArr do
        begin
          if not(itemVal is TJSONObject) then
            continue;
          itemObj := itemVal as TJSONObject;

          if SameText(getStr(itemObj, 'type'), 'selector') then
          begin
            sel.name := getStr(itemObj, 'tag');
            sel.defaultName := getStr(itemObj, 'default');
            sel.defaultIndex := -1;

            if itemObj.TryGetValue('outbounds', outboundsArr) then
            begin
              SetLength(sel.outbounds, outboundsArr.Count);
              for outboundI := 0 to outboundsArr.Count - 1 do
              begin
                outboundName := outboundsArr.Items[outboundI].value;
                sel.outbounds[outboundI] := outboundName;
                if sel.defaultName = outboundName then
                  sel.defaultIndex := outboundI;
              end;
            end
            else
            begin
              SetLength(sel.outbounds, 0);
            end;

            if Length(sel.outbounds) > 0 then
              selectorList.Add(sel);
          end;
        end;

        result.Selectors := selectorList.ToArray;
      finally
        selectorList.Free;
      end;
    end;

    result.clashApi.externalController := '';
    result.clashApi.secret := '';
    if rootObj.TryGetValue('experimental.clash_api', obj) then
    begin
      obj.TryGetValue('external_controller', result.clashApi.externalController);
      obj.TryGetValue('secret', result.clashApi.secret);
    end
    else if Length(result.Selectors) > 0 then
    begin
      CreateDefaultClashApi(rootObj, result);
    end;

    result.jsonWithTun := rootObj.ToString;

    if result.hasTunInbound then
    begin
      RemoveTunInbounds(rootObj);
      result.jsonWithoutTun := rootObj.ToString;
    end
    else
    begin
      result.jsonWithoutTun := result.jsonWithTun;
    end;
  finally
    rootValue.Free;
  end;
end;

procedure TDrover.CheckSingBoxConfig(cfg: TSingBoxConfig);
begin
  if (cfg.proxyHost = '') or (cfg.proxyPort < 1) then
    raise Exception.Create('No suitable mixed inbound found for the system proxy.');
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
