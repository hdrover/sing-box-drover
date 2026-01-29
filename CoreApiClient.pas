unit CoreApiClient;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, SingBoxConfig,
  System.Net.HttpClient, System.Net.URLClient, Logger;

type
  TCoreApiClient = class
  private
    FClashApiConfig: TClashApiConfig;
    FLogger: TLogger;
    FHttpClient: THTTPClient;

    procedure Log(const AMessage: string);
  public
    constructor Create(AClashApiConfig: TClashApiConfig; ALogger: TLogger);
    destructor Destroy; override;

    function IsConfigured: boolean;
    function CheckReady: boolean;
    procedure SendClashApiRequest(method, path, data: string);
  end;

implementation

constructor TCoreApiClient.Create(AClashApiConfig: TClashApiConfig; ALogger: TLogger);
begin
  FClashApiConfig := AClashApiConfig;
  FLogger := ALogger;

  FHttpClient := THTTPClient.Create;
  FHttpClient.ProxySettings := TProxySettings.Create('http://direct');
end;

destructor TCoreApiClient.Destroy;
begin
  FreeAndNil(FHttpClient);

  inherited;
end;

function TCoreApiClient.IsConfigured: boolean;
begin
  result := FClashApiConfig.IsConfigured;
end;

function TCoreApiClient.CheckReady: boolean;
begin
  result := false;

  if not IsConfigured then
    exit;

  try
    Log('API check...');
    SendClashApiRequest('GET', '/version', '');
    Log('API check: successful.');
    result := true;
  except
    on E: Exception do
    begin
      Log(trim('API check: failed. ' + E.Message));
    end;
  end;
end;

procedure TCoreApiClient.SendClashApiRequest(method, path, data: string);
var
  client: THTTPClient;
  body: TStringStream;
  headers: TNetHeaders;
  url: string;
  response: IHTTPResponse;
begin
  if not IsConfigured then
    raise Exception.Create('Clash API is not configured.');

  url := 'http://' + FClashApiConfig.externalController + path;

  client := FHttpClient;

  client.ConnectionTimeout := 1000;
  client.SendTimeout := 1000;
  client.ResponseTimeout := 1000;

  body := TStringStream.Create(data, TEncoding.UTF8);
  try
    SetLength(headers, 2);
    headers[0].name := 'Authorization';
    headers[0].value := 'Bearer ' + FClashApiConfig.secret;
    headers[1].name := 'Content-Type';
    headers[1].value := 'application/json';

    if SameText(method, 'GET') then
    begin
      response := client.Get(url, nil, headers);
    end
    else if SameText(method, 'PUT') then
    begin
      response := client.Put(url, body, nil, headers);
    end
    else if SameText(method, 'DELETE') then
    begin
      response := client.Delete(url, nil, headers);
    end
    else
    begin
      raise Exception.Create('Invalid method.');
    end;

    if response.StatusCode div 100 <> 2 then
      raise Exception.CreateFmt('HTTP %d.', [response.StatusCode]);
  finally
    body.Free;
  end;
end;

procedure TCoreApiClient.Log(const AMessage: string);
begin
  FLogger.Log('[API] ' + AMessage);
end;

end.
