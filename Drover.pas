unit Drover;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, SystemProxy, System.Net.HttpClient,
  System.Net.URLClient, System.JSON, System.IOUtils, System.Generics.Collections, Options, JsonUtils;

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
  end;

  TDrover = class
  public
    sbConfig: TSingBoxConfig;
    FOptions: TDroverOptions;
    currentProcessDir: string;

    constructor Create;
    procedure StartSingBox(const exePath, configPath: string);
    function ReadSingBoxConfig(configPath: string): TSingBoxConfig;
    procedure CheckSingBoxConfig(cfg: TSingBoxConfig);
    procedure ResetSelectors;
    procedure EditSelector(name, value: string);
    procedure SendApiRequest(method, path, data: string);
    procedure CreateSelectorThread(tasks: TSelectorThreadTasks);
    function EnableSystemProxy: boolean;
    function DisableSystemProxy: boolean;

    property Options: TDroverOptions read FOptions;
  end;

  TSelectorThread = class(TThread)
  protected
    FDrover: TDrover;
    tasks: TSelectorThreadTasks;

    procedure Execute(); override;

  public
    constructor Create(Drover: TDrover; tasks: TSelectorThreadTasks);
    destructor Destroy; override;
  end;

implementation

constructor TDrover.Create();
var
  configPath: string;
begin
  currentProcessDir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
  FOptions := LoadOptions(currentProcessDir + OPTIONS_FILENAME);
  configPath := FOptions.sbConfigFile;
  sbConfig := ReadSingBoxConfig(configPath);
  CheckSingBoxConfig(sbConfig);
  StartSingBox(FOptions.sbDir + 'sing-box.exe', configPath);
  ResetSelectors;
end;

procedure TDrover.StartSingBox(const exePath, configPath: string);
var
  info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION;
  jobHandle: THandle;
  si: STARTUPINFO;
  pi: PROCESS_INFORMATION;
  cmd, workDir: string;
begin
  if not TFile.Exists(exePath) then
    raise Exception.Create('sing-box executable not found.');

  if not TFile.Exists(configPath) then
    raise Exception.Create('Configuration file not found.');

  jobHandle := CreateJobObject(nil, 'SingBoxJob');
  if jobHandle = 0 then
    RaiseLastOSError;

  ZeroMemory(@info, SizeOf(info));
  info.BasicLimitInformation.LimitFlags := JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

  if not SetInformationJobObject(jobHandle, JobObjectExtendedLimitInformation, @info, SizeOf(info)) then
    RaiseLastOSError;

  ZeroMemory(@si, SizeOf(si));
  ZeroMemory(@pi, SizeOf(pi));
  si.cb := SizeOf(si);

  cmd := Format('"%s" run -c "%s"', [exePath, configPath]);
  workDir := ExtractFileDir(exePath);

  if not CreateProcess(nil, PChar(cmd), nil, nil, false, CREATE_NO_WINDOW, nil, PChar(workDir), si, pi) then
    RaiseLastOSError;

  try
    if not AssignProcessToJobObject(jobHandle, pi.hProcess) then
    begin
      TerminateProcess(pi.hProcess, 1);
      RaiseLastOSError;
    end;
  finally
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
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

        if SameText(getStr(itemObj, 'type'), 'mixed') then
        begin
          result.proxyHost := getStr(itemObj, 'listen');
          result.proxyPort := StrToIntDef(getStr(itemObj, 'listen_port'), 0);
        end;
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

end.
