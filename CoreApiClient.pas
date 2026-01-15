unit CoreApiClient;

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections, SingBoxConfig,
  System.Net.HttpClient, System.Net.URLClient;

type
  TCoreApiClient = class
  private
    FClashApiConfig: TClashApiConfig;
  public
    constructor Create(AClashApiConfig: TClashApiConfig);
    procedure SendClashApiRequest(method, path, data: string);
  end;

implementation

constructor TCoreApiClient.Create(AClashApiConfig: TClashApiConfig);
begin
  FClashApiConfig := AClashApiConfig;
end;

procedure TCoreApiClient.SendClashApiRequest(method, path, data: string);
var
  client: THTTPClient;
  body: TStringStream;
  headers: TNetHeaders;
  url: string;
  response: IHTTPResponse;
begin
  if FClashApiConfig.externalController = '' then
    exit;

  url := 'http://' + FClashApiConfig.externalController + path;

  client := THTTPClient.Create;
  try
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

      if SameText(method, 'PUT') then
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
  finally
    client.Free;
  end;
end;

end.
