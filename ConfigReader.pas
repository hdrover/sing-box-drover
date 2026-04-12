unit ConfigReader;

interface

uses
  System.SysUtils, System.JSON, System.IOUtils, System.Generics.Collections,
  JsonUtils, SingBoxConfig, SingBoxBpf;

function ReadConfigSource(configPath: string): TConfigSource;
function ReadSingBoxConfig(const jsonText: string): TSingBoxConfig;
procedure CheckSingBoxConfig(cfg: TSingBoxConfig);

implementation

procedure RemoveTunInbounds(rootObj: TJSONObject);
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

procedure CreateDefaultClashApi(rootObj: TJSONObject; var config: TSingBoxConfig);
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

function ReadConfigSource(configPath: string): TConfigSource;
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

function ReadSingBoxConfig(const jsonText: string): TSingBoxConfig;
var
  normalizedJson: string;
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

  normalizedJson := NormalizeJson(jsonText);
  rootValue := TJSONObject.ParseJSONValue(normalizedJson);
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

procedure CheckSingBoxConfig(cfg: TSingBoxConfig);
begin
  if (cfg.proxyHost = '') or (cfg.proxyPort < 1) then
    raise Exception.Create('No suitable mixed inbound found for the system proxy.');
end;

end.
