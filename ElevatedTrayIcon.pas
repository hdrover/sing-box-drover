unit ElevatedTrayIcon;

interface

uses
  System.Classes, Vcl.ExtCtrls, Winapi.Windows;

type
  TElevatedTrayIcon = class(TTrayIcon)
  public
    constructor Create(AOwner: TComponent); override;
  end;

implementation

const
  MSGFLT_ALLOW = 1;

function ChangeWindowMessageFilterEx(hwnd: hwnd; message: UINT; action: DWORD; pChangeFilterStruct: pointer): BOOL;
  stdcall; external 'user32.dll' name 'ChangeWindowMessageFilterEx';

constructor TElevatedTrayIcon.Create(AOwner: TComponent);
var
  msgId: UINT;
begin
  inherited Create(AOwner);
  msgId := RegisterWindowMessage('TaskbarCreated');
  ChangeWindowMessageFilterEx(Data.Wnd, msgId, MSGFLT_ALLOW, nil);
end;

end.
