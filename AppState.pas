unit AppState;

interface

uses
  System.SysUtils, System.IOUtils, System.JSON, System.Classes,
  System.Generics.Collections;

type
  TAppState = class
  private
    FFilePath: string;
    FSelectors: TDictionary<string, string>;
    FRoot: TJSONObject;
    procedure Load;
    procedure Save;
    function BuildJsonText: string;
  public
    constructor Create(const filePath: string);
    destructor Destroy; override;
    function GetSelector(const AName: string; out AValue: string): boolean;
    procedure SyncSelectors(values: TDictionary<string, string>; const scope: TArray<string>);
  end;

implementation

const
  KEY_SELECTORS = 'selectors';

constructor TAppState.Create(const filePath: string);
begin
  FFilePath := filePath;
  FSelectors := TDictionary<string, string>.Create;
  FRoot := TJSONObject.Create;
  Load;
end;

destructor TAppState.Destroy;
begin
  FreeAndNil(FRoot);
  FreeAndNil(FSelectors);
  inherited;
end;

procedure TAppState.Load;
var
  text: string;
  parsed: TJSONValue;
  newRoot: TJSONObject;
  selObj: TJSONObject;
  pair: TJSONPair;
begin
  newRoot := nil;
  try
    if not TFile.Exists(FFilePath) then
      Abort;

    text := TFile.ReadAllText(FFilePath, TEncoding.UTF8);
    if text = '' then
      Abort;

    parsed := TJSONObject.ParseJSONValue(text);
    if not(parsed is TJSONObject) then
    begin
      parsed.Free;
      Abort;
    end;
    newRoot := TJSONObject(parsed);

    if newRoot.TryGetValue<TJSONObject>(KEY_SELECTORS, selObj) then
      for pair in selObj do
        if pair.JsonValue is TJSONString then
          FSelectors.AddOrSetValue(pair.JsonString.Value, TJSONString(pair.JsonValue).Value);
  except
    FreeAndNil(newRoot);
    FSelectors.Clear;
  end;

  if newRoot = nil then
    newRoot := TJSONObject.Create;
  FRoot.Free;
  FRoot := newRoot;
end;

function TAppState.BuildJsonText: string;
var
  removed: TJSONPair;
  selObj: TJSONObject;
  pair: TPair<string, string>;
begin
  removed := FRoot.RemovePair(KEY_SELECTORS);
  if removed <> nil then
    removed.Free;

  selObj := TJSONObject.Create;
  FRoot.AddPair(KEY_SELECTORS, selObj);
  for pair in FSelectors do
    selObj.AddPair(pair.Key, pair.Value);

  result := FRoot.Format(2);
end;

procedure TAppState.Save;
begin
  TFile.WriteAllBytes(FFilePath, TEncoding.UTF8.GetBytes(BuildJsonText));
end;

function TAppState.GetSelector(const AName: string; out AValue: string): boolean;
begin
  result := FSelectors.TryGetValue(AName, AValue);
end;

procedure TAppState.SyncSelectors(values: TDictionary<string, string>; const scope: TArray<string>);
var
  pair: TPair<string, string>;
  name: string;
begin
  if (values.Count = 0) and (length(scope) = 0) then
    exit;

  for name in scope do
    if not values.ContainsKey(name) then
      FSelectors.Remove(name);

  for pair in values do
    FSelectors.AddOrSetValue(pair.Key, pair.Value);

  Save;
end;

end.
