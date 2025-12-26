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
  JsonUtils in 'JsonUtils.pas',
  CoreSupervisor in 'CoreSupervisor.pas',
  Logger in 'Logger.pas',
  AppArgs in 'AppArgs.pas',
  AppElevation in 'AppElevation.pas',
  AppSingleInstance in 'AppSingleInstance.pas';

{$R *.res}

const
  APP_TITLE = 'sing-box-drover';

var
  Drover: TDrover;
  flags: TAppFlags;
  s: string;

begin
  try
    flags := ParseAppFlags;

    if not AcquireSingleInstance('SingBoxDrover_SingleInstance_Mutex', afElevatedRestart in flags) then
      raise Exception.Create('Another instance of this application is already running.');

    Drover := TDrover.Create(flags);
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
