unit SingBoxConfig;

interface

type
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

end.
