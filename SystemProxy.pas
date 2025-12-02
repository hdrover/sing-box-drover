unit SystemProxy;

interface

function EnableSystemProxy(const host: string; port: word): boolean;
function DisableSystemProxy: boolean;

implementation

uses
  Windows, SysUtils, WinInet;

type
  INTERNET_PER_CONN_OPTION = record
    dwOption: DWORD;

    Value: record
      case Integer of
        1:
          (dwValue: DWORD);
        2:
          (pszValue: LPTSTR);
        3:
          (ftValue: TFileTime);
    end;
  end;

  LPINTERNET_PER_CONN_OPTION = ^INTERNET_PER_CONN_OPTION;

  INTERNET_PER_CONN_OPTION_LIST = record
    dwSize: DWORD;
    pszConnection: LPTSTR;
    dwOptionCount: DWORD;
    dwOptionError: DWORD;
    pOptions: LPINTERNET_PER_CONN_OPTION;
  end;

const
  INTERNET_PER_CONN_FLAGS = 1;
  INTERNET_PER_CONN_PROXY_SERVER = 2;
  INTERNET_PER_CONN_PROXY_BYPASS = 3;
  INTERNET_PER_CONN_AUTOCONFIG_URL = 4;
  INTERNET_PER_CONN_AUTODISCOVERY_FLAGS = 5;
  PROXY_TYPE_DIRECT = $00000001;
  PROXY_TYPE_PROXY = $00000002;
  PROXY_TYPE_AUTO_PROXY_URL = $00000004;
  PROXY_TYPE_AUTO_DETECT = $00000008;
  INTERNET_OPTION_REFRESH = 37;
  INTERNET_OPTION_PER_CONNECTION_OPTION = 75;
  INTERNET_OPTION_SETTINGS_CHANGED = 39;

function SetOptions(const proxyStr: string): boolean;
var
  list: INTERNET_PER_CONN_OPTION_LIST;
  opts: array [0 .. 2] of INTERNET_PER_CONN_OPTION;
begin
  ZeroMemory(@list, SizeOf(list));
  ZeroMemory(@opts, SizeOf(opts));

  list.dwSize := SizeOf(list);
  list.pszConnection := nil;
  list.pOptions := @opts[0];

  if proxyStr = '' then
  begin
    list.dwOptionCount := 1;
    opts[0].dwOption := INTERNET_PER_CONN_FLAGS;
    opts[0].Value.dwValue := PROXY_TYPE_DIRECT;
  end
  else
  begin
    list.dwOptionCount := 3;

    opts[0].dwOption := INTERNET_PER_CONN_FLAGS;
    opts[0].Value.dwValue := PROXY_TYPE_DIRECT or PROXY_TYPE_PROXY;

    opts[1].dwOption := INTERNET_PER_CONN_PROXY_SERVER;
    opts[1].Value.pszValue := PChar(proxyStr);

    opts[2].dwOption := INTERNET_PER_CONN_PROXY_BYPASS;
    opts[2].Value.pszValue := '<local>';
  end;

  result := InternetSetOption(nil, INTERNET_OPTION_PER_CONNECTION_OPTION, @list, SizeOf(list));

  if result then
  begin
    InternetSetOption(nil, INTERNET_OPTION_SETTINGS_CHANGED, nil, 0);
    InternetSetOption(nil, INTERNET_OPTION_REFRESH, nil, 0);
  end;
end;

function EnableSystemProxy(const host: string; port: word): boolean;
var
  valueStr, proxyStr: string;
begin
  valueStr := Format('%s:%d', [host, port]);
  proxyStr := Format('http=%s;https=%s;socks=%s', [valueStr, valueStr, valueStr]);
  result := SetOptions(proxyStr);
end;

function DisableSystemProxy: boolean;
begin
  result := SetOptions('');
end;

end.
