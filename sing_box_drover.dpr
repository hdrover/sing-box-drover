program sing_box_drover;

{$R *.dres}

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  Vcl.Forms,
  Main in 'Main.pas' {frmMain},
  SystemProxy in 'SystemProxy.pas',
  Drover in 'Drover.pas',
  Options in 'Options.pas',
  JsonUtils in 'JsonUtils.pas';

{$R *.res}

const
  APP_TITLE = 'sing-box-drover';

function IsSingleInstance: Boolean;
var
  hMutex: THandle;
begin
  result := false;
  hMutex := CreateMutex(nil, true, 'SingBoxDrover_SingleInstance_Mutex');
  if hMutex = 0 then
    exit;
  if (GetLastError = ERROR_ALREADY_EXISTS) or (GetLastError = ERROR_ACCESS_DENIED) then
    exit;
  result := true;
end;

var
  Drover: TDrover;
  s: string;

begin
  try
    if not IsSingleInstance then
      raise Exception.Create('Another instance of this application is already running.');

    Drover := TDrover.Create;
  except
    on E: Exception do
    begin
      s := E.Message;
      if s = '' then
        s := 'Unknown error.';

      MessageBox(0, PChar(s), PChar(APP_TITLE), MB_ICONERROR);
      exit;
    end;
  end;

  Application.Initialize;
  Application.Title := APP_TITLE;
  Application.MainFormOnTaskbar := false;
  Application.ShowMainForm := false;
  Application.CreateForm(TfrmMain, frmMain);
  frmMain.InitDrover(Drover);
  Application.Run;

end.
