unit AppElevation;

interface

uses
  Winapi.Windows,
  Winapi.ShellAPI,
  System.SysUtils;

function IsProcessElevated: boolean;
function RunAsAdminSelf(const params: string; ownerWnd: HWND = 0): boolean;

implementation

var
  GElevationCache: integer = 0;

function QueryIsProcessElevated: boolean;
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

function IsProcessElevated: boolean;
var
  elevated: boolean;
begin
  if GElevationCache <> 0 then
    exit(GElevationCache > 0);

  elevated := QueryIsProcessElevated;

  if elevated then
    GElevationCache := 1
  else
    GElevationCache := -1;

  result := elevated;
end;

function RunAsAdminSelf(const params: string; ownerWnd: HWND = 0): boolean;
var
  sei: TShellExecuteInfo;
begin
  ZeroMemory(@sei, SizeOf(sei));
  sei.cbSize := SizeOf(sei);
  sei.fMask := SEE_MASK_NOASYNC;
  sei.Wnd := ownerWnd;
  sei.lpVerb := PChar('runas');
  sei.lpFile := PChar(ParamStr(0));
  sei.lpParameters := PChar(params);
  sei.lpDirectory := PChar(ExtractFileDir(ParamStr(0)));
  sei.nShow := SW_SHOWNORMAL;

  result := ShellExecuteEx(@sei);
end;

end.
