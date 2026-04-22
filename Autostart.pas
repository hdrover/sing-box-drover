unit Autostart;

interface

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  System.Win.ComObj,
  System.Variants;

const
  WM_AUTOSTART_RESULT = WM_APP + 502;

type
  TAutostartAction = (aaCheck, aaEnable, aaDisable);

  TAutostartState = (asUnknown, asDisabled, asEnabled);

  TAutostartResult = record
    action: TAutostartAction;
    success: boolean;
    state: TAutostartState;
    errorMsg: string;
  end;

  PAutostartResult = ^TAutostartResult;

  TAutostartThread = class(TThread)
  private
    FAction: TAutostartAction;
    FHandle: HWND;
  protected
    procedure Execute; override;
  public
    constructor Create(AAction: TAutostartAction; AHandle: HWND);
  end;

implementation

const
  TASK_NAME = 'sing-box-drover';

  TASK_ACTION_EXEC = 0;
  TASK_TRIGGER_LOGON = 9;
  TASK_LOGON_INTERACTIVE_TOKEN = 3;
  TASK_RUNLEVEL_HIGHEST = 1;
  TASK_CREATE_OR_UPDATE = 6;
  TASK_INSTANCES_IGNORE_NEW = 2;

  HR_FILE_NOT_FOUND = HRESULT($80070002);

type
  EAutostart = class(Exception);

function AutostartErrorFrom(const E: Exception; const defaultMsg: string): Exception;
begin
  if E is EAutostart then
    result := E
  else
    result := EAutostart.Create(defaultMsg);
end;

function GetCurrentUserSamName: string;
var
  buf: array [0 .. 255] of char;
  bufLen: ULONG;
begin
  bufLen := Length(buf);
  if GetUserNameEx(NameSamCompatible, buf, bufLen) then
    result := buf
  else
    result := '';
end;

function ConnectScheduler: variant;
begin
  try
    result := CreateOleObject('Schedule.Service');
    result.Connect;
  except
    on E: Exception do
      raise AutostartErrorFrom(E, 'Failed to connect to Task Scheduler.');
  end;
end;

function IsNotFound(const E: EOleException): boolean;
begin
  result := HRESULT(E.ErrorCode) = HR_FILE_NOT_FOUND;
end;

function ProbeTaskState(const service: variant): TAutostartState;
var
  rootFolder, task, taskActions, action: variant;
  actionPath: string;
begin
  try
    rootFolder := service.GetFolder('\');

    try
      task := rootFolder.GetTask(TASK_NAME);
    except
      on E: EOleException do
        if IsNotFound(E) then
          exit(asDisabled)
        else
          raise;
    end;

    actionPath := '';
    try
      taskActions := task.Definition.Actions;
      if taskActions.Count >= 1 then
      begin
        action := taskActions.Item[1];
        actionPath := VarToStr(action.Path);
      end;
    except
      actionPath := '';
    end;

    if SameText(trim(actionPath), trim(ParamStr(0))) then
      result := asEnabled
    else
      result := asDisabled;
  except
    on E: Exception do
      raise AutostartErrorFrom(E, 'Failed to check autostart task.');
  end;
end;

procedure DoEnable(const service: variant);
var
  rootFolder, taskDef, trigger, action, taskPrincipal, taskSettings: variant;
  userSam: string;
begin
  try
    userSam := GetCurrentUserSamName;
    if userSam = '' then
      raise EAutostart.Create('Failed to resolve current user name.');

    rootFolder := service.GetFolder('\');
    taskDef := service.NewTask(0);

    taskDef.RegistrationInfo.Author := userSam;
    taskDef.RegistrationInfo.URI := '\' + TASK_NAME;

    taskPrincipal := taskDef.Principal;
    taskPrincipal.UserId := userSam;
    taskPrincipal.LogonType := TASK_LOGON_INTERACTIVE_TOKEN;
    taskPrincipal.RunLevel := TASK_RUNLEVEL_HIGHEST;

    taskSettings := taskDef.Settings;
    taskSettings.MultipleInstances := TASK_INSTANCES_IGNORE_NEW;
    taskSettings.DisallowStartIfOnBatteries := false;
    taskSettings.StopIfGoingOnBatteries := false;
    taskSettings.AllowHardTerminate := true;
    taskSettings.StartWhenAvailable := false;
    taskSettings.RunOnlyIfNetworkAvailable := false;
    taskSettings.IdleSettings.StopOnIdleEnd := false;
    taskSettings.IdleSettings.RestartOnIdle := false;
    taskSettings.AllowDemandStart := true;
    taskSettings.Enabled := true;
    taskSettings.Hidden := false;
    taskSettings.RunOnlyIfIdle := false;
    taskSettings.WakeToRun := false;
    taskSettings.ExecutionTimeLimit := 'PT0S';
    taskSettings.Priority := 7;

    trigger := taskDef.Triggers.Create(TASK_TRIGGER_LOGON);
    trigger.Enabled := true;
    trigger.UserId := userSam;

    action := taskDef.Actions.Create(TASK_ACTION_EXEC);
    action.Path := ParamStr(0);

    rootFolder.RegisterTaskDefinition(TASK_NAME, taskDef, TASK_CREATE_OR_UPDATE, '', '',
      TASK_LOGON_INTERACTIVE_TOKEN, '');
  except
    on E: Exception do
      raise AutostartErrorFrom(E, 'Failed to register autostart task.');
  end;
end;

procedure DoDisable(const service: variant);
var
  rootFolder: variant;
begin
  try
    rootFolder := service.GetFolder('\');
    try
      rootFolder.DeleteTask(TASK_NAME, 0);
    except
      on E: EOleException do
        if not IsNotFound(E) then
          raise;
    end;
  except
    on E: Exception do
      raise AutostartErrorFrom(E, 'Failed to remove autostart task.');
  end;
end;

constructor TAutostartThread.Create(AAction: TAutostartAction; AHandle: HWND);
begin
  FAction := AAction;
  FHandle := AHandle;
  FreeOnTerminate := true;
  inherited Create(false);
end;

procedure TAutostartThread.Execute;
var
  res: TAutostartResult;
  service: variant;
  p: PAutostartResult;
  hr: HRESULT;
begin
  res := Default (TAutostartResult);
  res.action := FAction;
  res.state := asUnknown;
  res.success := true;

  hr := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
  try
    try
      if not Succeeded(hr) then
        raise EAutostart.Create('Failed to initialize COM.');

      service := ConnectScheduler;

      try
        case FAction of
          aaEnable:
            DoEnable(service);
          aaDisable:
            DoDisable(service);
          aaCheck:
            ;
        end;
      except
        on E: Exception do
        begin
          res.success := false;
          res.errorMsg := E.Message;
        end;
      end;

      try
        res.state := ProbeTaskState(service);
      except
        on E: Exception do
          if FAction = aaCheck then
          begin
            res.success := false;
            res.errorMsg := E.Message;
          end;
      end;
    except
      on E: Exception do
      begin
        res.success := false;
        res.errorMsg := E.Message;
      end;
    end;
  finally
    VarClear(service);
    if Succeeded(hr) then
      CoUninitialize;
  end;

  New(p);
  p^ := res;
  if not PostMessage(FHandle, WM_AUTOSTART_RESULT, 0, LPARAM(p)) then
    Dispose(p);
end;

end.
