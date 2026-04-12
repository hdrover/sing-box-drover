unit SingBoxConfig;

interface

uses
  SingBoxBpf;

type
  TConfigSourceFormat = (csfJson, csfBpf);

  TConfigSelector = record
    name: string;
    outbounds: TArray<string>;
    defaultIndex: integer;
    defaultName: string;
  end;

  TConfigSelectors = TArray<TConfigSelector>;

  TClashApiConfig = record
    externalController: string;
    secret: string;

    function IsConfigured: boolean;
  end;

  TConfigSource = record
    filePath: string;
    format: TConfigSourceFormat;
    jsonText: string;
    bpfProfile: TBpfProfile;

    function isBpf: boolean;
  end;

  TSingBoxConfig = record
    clashApi: TClashApiConfig;
    selectors: TConfigSelectors;
    proxyHost: string;
    proxyPort: integer;
    hasTunInbound: boolean;
    jsonWithTun: string;
    jsonWithoutTun: string;
  end;

implementation

function TConfigSource.isBpf: boolean;
begin
  result := format = csfBpf;
end;

function TClashApiConfig.IsConfigured: boolean;
begin
  result := externalController <> '';
end;

end.
