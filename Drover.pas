unit Drover;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, SystemProxy, System.Net.HttpClient,
  System.Net.URLClient, System.JSON, System.IOUtils, System.Generics.Collections, Options, JsonUtils,
  CoreSupervisor, Logger;

const
  WM_DROVER_CAN_CLOSE = WM_APP + 501;

type
  TConfigSelector = record
    name: string;
    outbounds: TArray<string>;
    default: integer;
    defaultName: string;
  end;

  TConfigSelectors = TArray<TConfigSelector>;

  TSelectorThreadTask = record
    name, value: string;
  end;

  TSelectorThreadTasks = TArray<TSelectorThreadTask>;

  TSingBoxConfig = record
    clashApiExternalController, clashApiSecret: string;
    selectors: TConfigSelectors;
    proxyHost: string;
    proxyPort: integer;
    hasTunInbound: boolean;
    jsonWithTun: string;
    jsonWithoutTun: string;
  end;

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
    FIsAdmin: boolean;
    FIsTunActive: boolean;

    procedure SupervisorStateChanged(state: TCoreState; msg: string);
    procedure SupervisorTerminated(sender: TObject);
    procedure PostCanClose;
    procedure NotifyEvent(kind: TDroverEventKind; msg: string = '');
    procedure SetOnEvent(value: TDroverEventHandler);
    procedure FlushPendingEvents;
    procedure RemoveTunInbounds(rootObj: TJSONObject);
    function CheckIsAdmin: boolean;
  public
    sbConfig: TSingBoxConfig;
    FOptions: TDroverOptions;
    currentProcessDir: string;

    constructor Create;
    destructor Destroy; override;

    function ReadSingBoxConfig(configPath: string): TSingBoxConfig;
    procedure CheckSingBoxConfig(cfg: TSingBoxConfig);
    procedure ResetSelectors;
    procedure EditSelector(name, value: string);
    procedure SendApiRequest(method, path, data: string);
    procedure CreateSelectorThread(tasks: TSelectorThreadTasks);
    function EnableSystemProxy: boolean;
    function DisableSystemProxy: boolean;
    function Shutdown: boolean;
    procedure StartCore(useTun: boolean);
    function CanUseTun: boolean;

    property Options: TDroverOptions read FOptions;
    property OnEvent: TDroverEventHandler read FOnEvent write SetOnEvent;
    property NotifyHandle: HWND read FNotifyHandle write FNotifyHandle;
    property IsAdmin: boolean read FIsAdmin;
    property IsTunActive: boolean read FIsTunActive;
  end;

  TSelectorThread = class(TThread)
  protected
    FDrover: TDrover;
    tasks: TSelectorThreadTasks;

    procedure Execute; override;
  public
    constructor Create(Drover: TDrover; tasks: TSelectorThreadTasks);
    destructor Destroy; override;
  end;

implementation

constructor TDrover.Create;
var
  corePath: string;
begin
  FPendingEvents := TList<TDroverEvent>.Create;

  currentProcessDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));

  FOptions := TDroverOptions.Load(currentProcessDir + OPTIONS_FILENAME);

  FLogger := TLogger.Create(FOptions.logFile);

  sbConfig := ReadSingBoxConfig(FOptions.sbConfigFile);
  CheckSingBoxConfig(sbConfig);

  FIsAdmin := CheckIsAdmin;

  corePath := FOptions.sbDir + 'sing-box.exe';
  if not TFile.Exists(corePath) then
    raise Exception.Create('sing-box executable not found.');

  FSupervisor := TCoreSupervisor.Create(corePath, FLogger);
  FSupervisor.OnStateChanged := SupervisorStateChanged;
  FSupervisor.OnTerminate := SupervisorTerminated;
  StartCore(CanUseTun and (FOptions.tunStartMode = tsmOn));
end;

destructor TDrover.Destroy;
begin
  FDestroying := true;

  if Assigned(FSupervisor) then
  begin
    FSupervisor.OnStateChanged := nil;
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
  result := sbConfig.hasTunInbound and IsAdmin;
end;

function TDrover.CheckIsAdmin: boolean;
var
  tokenHandle: THandle;
  elevation: TOKEN_ELEVATION;
  returnLength: DWORD;
begin
  result := false;
  if OpenProcessToken(GetCurrentProcess, TOKEN_QUERY, tokenHandle) then
    try
      if GetTokenInformation(tokenHandle, TokenElevation, @elevation, SizeOf(elevation), returnLength) then
        result := elevation.TokenIsElevated <> 0;
    finally
      CloseHandle(tokenHandle);
    end;
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

procedure TDrover.SupervisorStateChanged(state: TCoreState; msg: string);
begin
  if FDestroying or FShutdownRequested then
    exit;

  case state of
    csRunning:
      begin
        ResetSelectors;
        NotifyEvent(dekRunning, '');
      end;

    csFailed:
      NotifyEvent(dekError, msg);
  end;
end;

procedure TDrover.SupervisorTerminated(sender: TObject);
begin
  if FDestroying then
    exit;

  if FShutdownRequested then
  begin
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

function TDrover.ReadSingBoxConfig(configPath: string): TSingBoxConfig;
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
  list: TList<TConfigSelector>;
  inboundType: string;

  function getStr(const obj: TJSONObject; const name: string; const ADefault: string = ''): string;
  begin
    if not obj.TryGetValue(name, result) then
      result := ADefault;
  end;

begin
  result := Default (TSingBoxConfig);

  if not TFile.Exists(configPath) then
    raise Exception.Create('Configuration file not found.');

  jsonText := TFile.ReadAllText(configPath, TEncoding.UTF8);
  jsonText := NormalizeJson(jsonText);
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
      list := TList<TConfigSelector>.Create;
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
            sel.default := -1;

            if itemObj.TryGetValue('outbounds', outboundsArr) then
            begin
              SetLength(sel.outbounds, outboundsArr.Count);
              for outboundI := 0 to outboundsArr.Count - 1 do
              begin
                outboundName := outboundsArr.Items[outboundI].value;
                sel.outbounds[outboundI] := outboundName;
                if sel.defaultName = outboundName then
                  sel.default := outboundI;
              end;
            end
            else
            begin
              SetLength(sel.outbounds, 0);
            end;

            if Length(sel.outbounds) > 0 then
              list.Add(sel);
          end;
        end;

        result.selectors := list.ToArray;
      finally
        list.Free;
      end;
    end;

    result.clashApiExternalController := '';
    result.clashApiSecret := '';
    if rootObj.TryGetValue('experimental.clash_api', obj) then
    begin
      obj.TryGetValue('external_controller', result.clashApiExternalController);
      obj.TryGetValue('secret', result.clashApiSecret);
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

procedure TDrover.CreateSelectorThread(tasks: TSelectorThreadTasks);
begin
  TSelectorThread.Create(self, tasks);
end;

procedure TDrover.ResetSelectors;
var
  selector: TConfigSelector;
  outboundI: integer;
  outboundName: string;
  task: TSelectorThreadTask;
  tasks: TSelectorThreadTasks;
  taskI: integer;
begin
  SetLength(tasks, Length(sbConfig.selectors));
  taskI := 0;

  for selector in sbConfig.selectors do
  begin
    for outboundI := Low(selector.outbounds) to High(selector.outbounds) do
    begin
      outboundName := selector.outbounds[outboundI];

      if (outboundI = selector.default) then
      begin
        task.name := selector.name;
        task.value := outboundName;
        tasks[taskI] := task;
        inc(taskI);
      end;
    end;
  end;

  if taskI < 1 then
    exit;

  SetLength(tasks, taskI);

  CreateSelectorThread(tasks);
end;

procedure TDrover.EditSelector(name, value: string);
var
  task: TSelectorThreadTask;
begin
  task.name := name;
  task.value := value;
  CreateSelectorThread([task]);
end;

function TDrover.EnableSystemProxy: boolean;
begin
  result := SystemProxy.EnableSystemProxy(sbConfig.proxyHost, sbConfig.proxyPort);
end;

function TDrover.DisableSystemProxy: boolean;
begin
  result := SystemProxy.DisableSystemProxy;
end;

constructor TSelectorThread.Create(Drover: TDrover; tasks: TSelectorThreadTasks);
begin
  self.FDrover := Drover;
  self.tasks := tasks;

  FreeOnTerminate := true;
  inherited Create(false);
end;

destructor TSelectorThread.Destroy;
begin
  inherited Destroy;
end;

procedure TDrover.SendApiRequest(method, path, data: string);
var
  client: THTTPClient;
  body: TStringStream;
  headers: TNetHeaders;
  url: string;
begin
  if sbConfig.clashApiExternalController = '' then
    exit;

  url := 'http://' + sbConfig.clashApiExternalController + path;

  client := THTTPClient.Create;
  try
    body := TStringStream.Create(data, TEncoding.UTF8);
    try
      SetLength(headers, 2);
      headers[0].name := 'Authorization';
      headers[0].value := 'Bearer ' + sbConfig.clashApiSecret;
      headers[1].name := 'Content-Type';
      headers[1].value := 'application/json';

      if SameText(method, 'PUT') then
      begin
        client.Put(url, body, nil, headers);
      end
      else if SameText(method, 'DELETE') then
      begin
        client.Delete(url, nil, headers);
      end;
    finally
      body.Free;
    end;
  finally
    client.Free;
  end;
end;

procedure TSelectorThread.Execute;
var
  task: TSelectorThreadTask;
begin
  for task in self.tasks do
  begin
    FDrover.SendApiRequest('PUT', '/proxies/' + task.name, '{"name":"' + task.value + '"}');
  end;

  FDrover.SendApiRequest('DELETE', '/connections', '');
end;

function TDrover.Shutdown: boolean;
begin
  if FShutdownComplete then
    exit(true);

  if (not Assigned(FSupervisor)) or FSupervisor.Finished then
  begin
    FShutdownComplete := true;
    exit(true);
  end;

  if not FShutdownRequested then
  begin
    FShutdownRequested := true;
    FSupervisor.OnStateChanged := nil;
    FSupervisor.Terminate;
    TThread.RemoveQueuedEvents(FSupervisor);
  end;

  result := false;
end;

procedure TDrover.PostCanClose;
begin
  if (FNotifyHandle <> 0) and IsWindow(FNotifyHandle) then
    PostMessage(FNotifyHandle, WM_DROVER_CAN_CLOSE, 0, 0);
end;

end.
