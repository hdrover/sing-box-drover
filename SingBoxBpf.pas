unit SingBoxBpf;

interface

uses
  System.Classes,
  System.SysUtils;

const
  BPF_MESSAGE_TYPE_PROFILE_CONTENT = 3;

  BPF_PROFILE_TYPE_LOCAL = 0;
  BPF_PROFILE_TYPE_ICLOUD = 1;
  BPF_PROFILE_TYPE_REMOTE = 2;

  BPF_VERSION_0 = 0;
  BPF_VERSION_1 = 1;
  BPF_CURRENT_VERSION = BPF_VERSION_1;

type
  EBpfProfileError = class(Exception);

  TBpfProfile = record
    version: byte;
    name: string;
    profileType: int32;
    configJson: string;
    remotePath: string;
    autoUpdate: boolean;
    autoUpdateInterval: int32;
    lastUpdated: int64;

    function isLocal: boolean;
    function isRemote: boolean;
  end;

function LooksLikeBpfProfileData(const AData: TBytes): boolean;
function DecodeBpfProfile(const AData: TBytes): TBpfProfile;
function TryDecodeBpfProfile(const AData: TBytes; out AProfile: TBpfProfile): boolean;
function EncodeBpfProfile(const AProfile: TBpfProfile): TBytes;
procedure WriteBpfProfileToFile(const AFileName: string; const AProfile: TBpfProfile);
function ReadBpfProfileFromFile(const AFileName: string): TBpfProfile;
function CreateLocalBpfProfile(const AConfigJson: string; const AName: string = ''): TBpfProfile;
function CreateRemoteBpfProfile(const AConfigJson, AName, ARemotePath: string; AAutoUpdate: boolean;
  AAutoUpdateInterval: int32; ALastUpdated: int64): TBpfProfile;

implementation

uses
  System.IOUtils,
  System.ZLib;

const
  ZLIB_MAX_WINDOW_BITS = 15;
  ZLIB_GZIP_FLAG = 16;
  ZLIB_AUTODETECT_ZLIB_OR_GZIP_FLAG = 32;

  GZIP_WINDOW_BITS = ZLIB_MAX_WINDOW_BITS + ZLIB_GZIP_FLAG;
  GZIP_OR_ZLIB_WINDOW_BITS = ZLIB_MAX_WINDOW_BITS + ZLIB_AUTODETECT_ZLIB_OR_GZIP_FLAG;

function RequireRange(const AData: TBytes; APosition, ACount: integer): integer;
begin
  if (APosition < 0) or (ACount < 0) or (APosition > Length(AData) - ACount) then
    raise EBpfProfileError.Create('Unexpected end of BPF data.');
  result := APosition;
end;

function BytesFromStream(AStream: TBytesStream): TBytes;
begin
  result := Copy(AStream.Bytes, 0, AStream.Size);
end;

function ReadByte(const AData: TBytes; var APosition: integer): byte;
begin
  RequireRange(AData, APosition, SizeOf(result));
  result := AData[APosition];
  inc(APosition);
end;

function ReadBoolByte(const AData: TBytes; var APosition: integer): boolean;
var
  value: byte;
begin
  value := ReadByte(AData, APosition);
  case value of
    0:
      result := false;
    1:
      result := true;
  else
    raise EBpfProfileError.Create('Invalid BPF boolean value.');
  end;
end;

function ReadUVarInt(const AData: TBytes; var APosition: integer): UInt64;
var
  shift: integer;
  value: byte;
begin
  result := 0;
  shift := 0;

  while shift <= 63 do
  begin
    value := ReadByte(AData, APosition);
    if (shift = 63) and (value > 1) then
      raise EBpfProfileError.Create('Invalid BPF varint.');

    result := result or (UInt64(value and $7F) shl shift);
    if (value and $80) = 0 then
      exit;
    inc(shift, 7);
  end;

  raise EBpfProfileError.Create('Invalid BPF varint.');
end;

function ReadInt32BE(const AData: TBytes; var APosition: integer): int32;
var
  buffer: array [0 .. 3] of byte;
  value: UInt32;
begin
  RequireRange(AData, APosition, SizeOf(buffer));
  Move(AData[APosition], buffer[0], SizeOf(buffer));
  inc(APosition, SizeOf(buffer));

  value := (UInt32(buffer[0]) shl 24) or (UInt32(buffer[1]) shl 16) or (UInt32(buffer[2]) shl 8) or UInt32(buffer[3]);
  result := int32(value);
end;

function ReadInt64BE(const AData: TBytes; var APosition: integer): int64;
var
  buffer: array [0 .. 7] of byte;
  value: UInt64;
begin
  RequireRange(AData, APosition, SizeOf(buffer));
  Move(AData[APosition], buffer[0], SizeOf(buffer));
  inc(APosition, SizeOf(buffer));

  value := (UInt64(buffer[0]) shl 56) or (UInt64(buffer[1]) shl 48) or (UInt64(buffer[2]) shl 40) or
    (UInt64(buffer[3]) shl 32) or (UInt64(buffer[4]) shl 24) or (UInt64(buffer[5]) shl 16) or (UInt64(buffer[6]) shl 8)
    or UInt64(buffer[7]);
  result := int64(value);
end;

function ReadStringUtf8(const AData: TBytes; var APosition: integer): string;
var
  byteCount: UInt64;
  count: integer;
begin
  byteCount := ReadUVarInt(AData, APosition);
  if byteCount > UInt64(High(integer)) then
    raise EBpfProfileError.Create('BPF string is too large.');

  count := integer(byteCount);
  RequireRange(AData, APosition, count);
  result := TEncoding.UTF8.GetString(Copy(AData, APosition, count));
  inc(APosition, count);
end;

procedure WriteByte(AStream: TStream; AValue: byte);
begin
  AStream.WriteBuffer(AValue, SizeOf(AValue));
end;

procedure WriteBoolByte(AStream: TStream; AValue: boolean);
begin
  if AValue then
    WriteByte(AStream, 1)
  else
    WriteByte(AStream, 0);
end;

procedure WriteUVarInt(AStream: TStream; AValue: UInt64);
var
  current: byte;
begin
  repeat
    current := byte(AValue and $7F);
    AValue := AValue shr 7;
    if AValue <> 0 then
      current := current or $80;
    WriteByte(AStream, current);
  until AValue = 0;
end;

procedure WriteInt32BE(AStream: TStream; AValue: int32);
var
  buffer: array [0 .. 3] of byte;
  value: UInt32;
begin
  value := UInt32(AValue);
  buffer[0] := byte(value shr 24);
  buffer[1] := byte(value shr 16);
  buffer[2] := byte(value shr 8);
  buffer[3] := byte(value);
  AStream.WriteBuffer(buffer, SizeOf(buffer));
end;

procedure WriteInt64BE(AStream: TStream; AValue: int64);
var
  buffer: array [0 .. 7] of byte;
  value: UInt64;
begin
  value := UInt64(AValue);
  buffer[0] := byte(value shr 56);
  buffer[1] := byte(value shr 48);
  buffer[2] := byte(value shr 40);
  buffer[3] := byte(value shr 32);
  buffer[4] := byte(value shr 24);
  buffer[5] := byte(value shr 16);
  buffer[6] := byte(value shr 8);
  buffer[7] := byte(value);
  AStream.WriteBuffer(buffer, SizeOf(buffer));
end;

procedure WriteStringUtf8(AStream: TStream; const AValue: string);
var
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(AValue);
  WriteUVarInt(AStream, UInt64(Length(Bytes)));
  if Length(Bytes) > 0 then
    AStream.WriteBuffer(Bytes[0], Length(Bytes));
end;

function GZipCompress(const AData: TBytes): TBytes;
var
  outStream: TBytesStream;
  compressor: TZCompressionStream;
begin
  outStream := TBytesStream.Create;
  try
    compressor := TZCompressionStream.Create(outStream, zcDefault, GZIP_WINDOW_BITS);
    try
      if Length(AData) > 0 then
        compressor.WriteBuffer(AData[0], Length(AData));
    finally
      compressor.Free;
    end;

    result := BytesFromStream(outStream);
  finally
    outStream.Free;
  end;
end;

function GZipDecompress(const AData: TBytes): TBytes;
var
  inStream: TBytesStream;
  outStream: TBytesStream;
  decompressor: TZDecompressionStream;
begin
  inStream := TBytesStream.Create(AData);
  outStream := TBytesStream.Create;
  try
    decompressor := TZDecompressionStream.Create(inStream, GZIP_OR_ZLIB_WINDOW_BITS);
    try
      outStream.CopyFrom(decompressor, 0);
    finally
      decompressor.Free;
    end;

    result := BytesFromStream(outStream);
  finally
    outStream.Free;
    inStream.Free;
  end;
end;

function NormalizeVersion(AValue: byte): byte;
begin
  if AValue = BPF_VERSION_0 then
    result := BPF_CURRENT_VERSION
  else
    result := AValue;
end;

function LooksLikeBpfProfileData(const AData: TBytes): boolean;
const
  GZIP_MAGIC_BYTE_1 = $1F;
  GZIP_MAGIC_BYTE_2 = $8B;
begin
  result := (Length(AData) >= 4) and (AData[0] = BPF_MESSAGE_TYPE_PROFILE_CONTENT) and (AData[2] = GZIP_MAGIC_BYTE_1)
    and (AData[3] = GZIP_MAGIC_BYTE_2);
end;

function DecodeBpfProfile(const AData: TBytes): TBpfProfile;
var
  position: integer;
  payload: TBytes;
begin
  if not LooksLikeBpfProfileData(AData) then
    raise EBpfProfileError.Create('Data is not a BPF profile.');

  result := Default (TBpfProfile);

  try
    position := 0;

    if ReadByte(AData, position) <> BPF_MESSAGE_TYPE_PROFILE_CONTENT then
      raise EBpfProfileError.Create('Unsupported BPF message type.');

    result.version := ReadByte(AData, position);
    if result.version > BPF_CURRENT_VERSION then
      raise EBpfProfileError.CreateFmt('Unsupported BPF version: %d.', [result.version]);

    payload := GZipDecompress(Copy(AData, position, Length(AData) - position));

    position := 0;
    result.name := ReadStringUtf8(payload, position);
    result.profileType := ReadInt32BE(payload, position);
    result.configJson := ReadStringUtf8(payload, position);

    if result.profileType <> BPF_PROFILE_TYPE_LOCAL then
      result.remotePath := ReadStringUtf8(payload, position);

    if (result.profileType = BPF_PROFILE_TYPE_REMOTE) or
      ((result.version = BPF_VERSION_0) and (result.profileType <> BPF_PROFILE_TYPE_LOCAL)) then
    begin
      result.autoUpdate := ReadBoolByte(payload, position);
      if result.version >= BPF_VERSION_1 then
        result.autoUpdateInterval := ReadInt32BE(payload, position);
      result.lastUpdated := ReadInt64BE(payload, position);
    end;
  except
    on E: EBpfProfileError do
      raise;
    on E: Exception do
      raise EBpfProfileError.CreateFmt('Failed to decode BPF profile (%s).', [E.ClassName]);
  end;
end;

function TryDecodeBpfProfile(const AData: TBytes; out AProfile: TBpfProfile): boolean;
begin
  AProfile := Default (TBpfProfile);
  if not LooksLikeBpfProfileData(AData) then
    exit(false);

  try
    AProfile := DecodeBpfProfile(AData);
    result := true;
  except
    AProfile := Default (TBpfProfile);
    result := false;
  end;
end;

function EncodeBpfProfile(const AProfile: TBpfProfile): TBytes;
var
  profile: TBpfProfile;
  payloadStream: TBytesStream;
  payload, compressedPayload: TBytes;
begin
  profile := AProfile;
  profile.version := NormalizeVersion(profile.version);

  payloadStream := TBytesStream.Create;
  try
    WriteStringUtf8(payloadStream, profile.name);
    WriteInt32BE(payloadStream, profile.profileType);
    WriteStringUtf8(payloadStream, profile.configJson);

    if profile.profileType <> BPF_PROFILE_TYPE_LOCAL then
      WriteStringUtf8(payloadStream, profile.remotePath);

    if profile.profileType = BPF_PROFILE_TYPE_REMOTE then
    begin
      WriteBoolByte(payloadStream, profile.autoUpdate);
      WriteInt32BE(payloadStream, profile.autoUpdateInterval);
      WriteInt64BE(payloadStream, profile.lastUpdated);
    end;

    payload := BytesFromStream(payloadStream);
  finally
    payloadStream.Free;
  end;

  compressedPayload := GZipCompress(payload);

  SetLength(result, 2 + Length(compressedPayload));
  result[0] := BPF_MESSAGE_TYPE_PROFILE_CONTENT;
  result[1] := profile.version;
  if Length(compressedPayload) > 0 then
    Move(compressedPayload[0], result[2], Length(compressedPayload));
end;

procedure WriteBpfProfileToFile(const AFileName: string; const AProfile: TBpfProfile);
begin
  try
    TFile.WriteAllBytes(AFileName, EncodeBpfProfile(AProfile));
  except
    raise EBpfProfileError.Create('Failed to write BPF profile file.');
  end;
end;

function ReadBpfProfileFromFile(const AFileName: string): TBpfProfile;
begin
  try
    result := DecodeBpfProfile(TFile.ReadAllBytes(AFileName));
  except
    on E: EBpfProfileError do
      raise;
    on E: Exception do
      raise EBpfProfileError.Create('Failed to read BPF profile file.');
  end;
end;

function CreateLocalBpfProfile(const AConfigJson: string; const AName: string = ''): TBpfProfile;
begin
  result := Default (TBpfProfile);
  result.version := BPF_CURRENT_VERSION;
  result.name := AName;
  result.profileType := BPF_PROFILE_TYPE_LOCAL;
  result.configJson := AConfigJson;
end;

function CreateRemoteBpfProfile(const AConfigJson, AName, ARemotePath: string; AAutoUpdate: boolean;
  AAutoUpdateInterval: int32; ALastUpdated: int64): TBpfProfile;
begin
  result := Default (TBpfProfile);
  result.version := BPF_CURRENT_VERSION;
  result.name := AName;
  result.profileType := BPF_PROFILE_TYPE_REMOTE;
  result.configJson := AConfigJson;
  result.remotePath := ARemotePath;
  result.autoUpdate := AAutoUpdate;
  result.autoUpdateInterval := AAutoUpdateInterval;
  result.lastUpdated := ALastUpdated;
end;

function TBpfProfile.isLocal: boolean;
begin
  result := profileType = BPF_PROFILE_TYPE_LOCAL;
end;

function TBpfProfile.isRemote: boolean;
begin
  result := profileType = BPF_PROFILE_TYPE_REMOTE;
end;

end.
