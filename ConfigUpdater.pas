unit ConfigUpdater;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Net.HttpClient, System.Net.URLClient, Logger, SingBoxCli, SingBoxConfig;

type
  TConfigUpdater = class(TThread)
  private
    FConfigSource: TConfigSource;
    FSingBoxCli: TSingBoxCli;
    FLogger: TLogger;
    FStopEvent: TEvent;
    FRequest: IHTTPRequest;
    FRequestLock: TCriticalSection;

    function ClampIntervalMs(AIntervalMinutes: int32): Cardinal;
    function GetCurrentProfileTimestamp: int64;
    function BuildUserAgent: string;
    procedure ClearActiveRequest;
    procedure DoUpdate;
    procedure Log(const AMessage: string);
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    constructor Create(const AConfigSource: TConfigSource; ASingBoxCli: TSingBoxCli; ALogger: TLogger);
    destructor Destroy; override;
  end;

implementation

uses
  System.DateUtils,
  ConfigReader,
  SingBoxBpf;

const
  INITIAL_DELAY_MS = 60000;
  MIN_INTERVAL_MINUTES = 15;
  MS_PER_MINUTE = 60000;
  CONNECTION_TIMEOUT_MS = 15000;
  SEND_TIMEOUT_MS = 15000;
  RESPONSE_TIMEOUT_MS = 30000;

constructor TConfigUpdater.Create(const AConfigSource: TConfigSource; ASingBoxCli: TSingBoxCli; ALogger: TLogger);
begin
  FConfigSource := AConfigSource;
  FSingBoxCli := ASingBoxCli;
  FLogger := ALogger;

  FStopEvent := TEvent.Create(nil, true, false, '');
  FRequestLock := TCriticalSection.Create;

  FreeOnTerminate := false;
  inherited Create(false);
end;

destructor TConfigUpdater.Destroy;
begin
  Terminate;
  WaitFor;

  FreeAndNil(FStopEvent);
  FreeAndNil(FRequestLock);

  inherited;
end;

function TConfigUpdater.ClampIntervalMs(AIntervalMinutes: int32): Cardinal;
var
  intervalMinutes: int64;
begin
  intervalMinutes := AIntervalMinutes;
  if intervalMinutes < MIN_INTERVAL_MINUTES then
    intervalMinutes := MIN_INTERVAL_MINUTES;

  result := Cardinal(intervalMinutes * MS_PER_MINUTE);
end;

function TConfigUpdater.GetCurrentProfileTimestamp: int64;
begin
  result := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now)) * 1000;
end;

procedure TConfigUpdater.Execute;
var
  intervalMs: Cardinal;
begin
  intervalMs := ClampIntervalMs(FConfigSource.bpfProfile.autoUpdateInterval);

  if FStopEvent.WaitFor(INITIAL_DELAY_MS) <> wrTimeout then
    exit;

  while not Terminated do
  begin
    DoUpdate;

    if FStopEvent.WaitFor(intervalMs) <> wrTimeout then
      break;
  end;
end;

procedure TConfigUpdater.ClearActiveRequest;
begin
  FRequestLock.Enter;
  try
    FRequest := nil;
  finally
    FRequestLock.Leave;
  end;
end;

function TConfigUpdater.BuildUserAgent: string;
var
  version: string;
begin
  result := 'sing-box-drover';
  version := FSingBoxCli.GetVersion;
  if version <> '' then
    result := result + ' (sing-box ' + version + ')';
end;

procedure TConfigUpdater.DoUpdate;
var
  http: THTTPClient;
  response: IHTTPResponse;
  jsonText: string;
  testConfig: TSingBoxConfig;
  updatedProfile: TBpfProfile;
begin
  if Terminated then
    exit;

  Log('Config update started.');

  try
    http := THTTPClient.Create;
    try
      http.UserAgent := BuildUserAgent;
      http.ConnectionTimeout := CONNECTION_TIMEOUT_MS;
      http.SendTimeout := SEND_TIMEOUT_MS;
      http.ResponseTimeout := RESPONSE_TIMEOUT_MS;

      FRequestLock.Enter;
      try
        if Terminated then
          exit;
        FRequest := http.GetRequest(sHTTPMethodGet, FConfigSource.bpfProfile.remotePath);
      finally
        FRequestLock.Leave;
      end;

      try
        response := http.Execute(FRequest);
      finally
        ClearActiveRequest;
      end;
    finally
      http.Free;
    end;

    if Terminated then
      exit;

    if response.StatusCode div 100 <> 2 then
      raise Exception.CreateFmt('HTTP %d.', [response.StatusCode]);

    jsonText := response.ContentAsString(TEncoding.UTF8);

    testConfig := ConfigReader.ReadSingBoxConfig(jsonText);
    ConfigReader.CheckSingBoxConfig(testConfig);

    if Terminated then
      exit;

    updatedProfile := FConfigSource.bpfProfile;
    updatedProfile.configJson := jsonText;
    updatedProfile.lastUpdated := GetCurrentProfileTimestamp;

    WriteBpfProfileToFile(FConfigSource.filePath, updatedProfile);
    FConfigSource.bpfProfile := updatedProfile;
    FConfigSource.jsonText := jsonText;

    Log('Config updated successfully.');
  except
    on E: Exception do
      Log(trim('Config update failed. ' + E.Message));
  end;
end;

procedure TConfigUpdater.TerminatedSet;
var
  request: IHTTPRequest;
begin
  inherited;

  FStopEvent.SetEvent;

  FRequestLock.Enter;
  try
    request := FRequest;
  finally
    FRequestLock.Leave;
  end;

  if Assigned(request) then
  begin
    Log('Cancelling active request.');
    try
      request.Cancel;
    except
    end;
  end;
end;

procedure TConfigUpdater.Log(const AMessage: string);
begin
  FLogger.Log('ConfigUpdater', AMessage);
end;

end.
