unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, System.Net.HttpClient,
  System.Net.URLClient, System.JSON, System.IOUtils, System.Generics.Collections, Options, Drover,
  AppElevation, AppArgs, SingBoxConfig, ElevatedTrayIcon, Autostart, Winapi.ShellAPI, CoreSupervisor;

type
  TPendingSelectorRequests = TDictionary<NativeInt, TMenuItem>;

  TfrmMain = class(TForm)
    PopupMenu: TPopupMenu;
    miQuit: TMenuItem;
    miSystemProxy: TMenuItem;
    miBeforeSelectors: TMenuItem;
    miTun: TMenuItem;
    miExtras: TMenuItem;
    miAutostart: TMenuItem;
    miRestart: TMenuItem;
    miHomepage: TMenuItem;
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure miQuitClick(Sender: TObject);
    procedure miSystemProxyClick(Sender: TObject);
    procedure TrayIconClick(Sender: TObject);
    procedure miSelectorClick(Sender: TObject);
    procedure DrawSelectors;
    procedure FormCreate(Sender: TObject);
    procedure miTunClick(Sender: TObject);
    procedure miAutostartClick(Sender: TObject);
    procedure miRestartClick(Sender: TObject);
    procedure miHomepageClick(Sender: TObject);
  private
    TrayIcon: TElevatedTrayIcon;
    FDrover: TDrover;
    FIsTunActive: boolean;
    FIsSystemProxyActive: boolean;
    FClosePending: boolean;
    FLastRequestId: NativeInt;
    FPendingSelectorRequests: TPendingSelectorRequests;

    function NewRequestId: NativeInt;
    procedure UpdateTrayIcon;
    procedure ToggleSystemProxy(AEnable: boolean; AUpdateTrayIcon: boolean = true);
    procedure ToggleTunDisplay(AActive: boolean; AUpdateTrayIcon: boolean = true);
    procedure ToggleTun(AEnable: boolean);
    procedure HandleDroverEvent(event: TDroverEvent);
    procedure WMDroverCanClose(var msg: TMessage); message WM_DROVER_CAN_CLOSE;
    procedure WMAutostartResult(var msg: TMessage); message WM_AUTOSTART_RESULT;
    procedure ShowBalloon(AText, ATitle: string; AFlags: TBalloonFlags = bfInfo; ATimeout: integer = 10000);
    procedure ShowOnlyExitInTray;
    procedure InitAutostart;
    procedure StartAutostartThread(AAction: TAutostartAction);
    procedure HandleAutostartResult(const r: TAutostartResult);
  public

    destructor Destroy; override;
    procedure InitDrover(ADrover: TDrover);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FIsTunActive := false;
  FIsSystemProxyActive := false;
  FClosePending := false;
  FLastRequestId := 0;
  FPendingSelectorRequests := TPendingSelectorRequests.Create;

  miTun.Enabled := false;
  miTun.Visible := false;

  TrayIcon := TElevatedTrayIcon.Create(self);
  TrayIcon.PopupMenu := PopupMenu;
  TrayIcon.OnClick := TrayIconClick;

  InitAutostart;
end;

destructor TfrmMain.Destroy;
begin
  FreeAndNil(FPendingSelectorRequests);
  inherited;
end;

function TfrmMain.NewRequestId: NativeInt;
begin
  inc(FLastRequestId);
  result := FLastRequestId;
end;

procedure TfrmMain.InitAutostart;
var
  flags: TAppFlags;
  initialAction: TAutostartAction;
begin
  miAutostart.Enabled := false;
  miAutostart.Checked := false;

  flags := GetAppFlags;
  if afAutostartEnable in flags then
    initialAction := aaEnable
  else if afAutostartDisable in flags then
    initialAction := aaDisable
  else
    initialAction := aaCheck;

  StartAutostartThread(initialAction);
end;

procedure TfrmMain.StartAutostartThread(AAction: TAutostartAction);
begin
  miAutostart.Enabled := false;
  TAutostartThread.Create(AAction, Handle);
end;

procedure TfrmMain.WMAutostartResult(var msg: TMessage);
var
  p: PAutostartResult;
begin
  p := PAutostartResult(msg.LParam);
  if p = nil then
    exit;
  try
    HandleAutostartResult(p^);
  finally
    Dispose(p);
  end;
end;

procedure TfrmMain.HandleAutostartResult(const r: TAutostartResult);
begin
  miAutostart.Enabled := r.state <> asUnknown;
  miAutostart.Checked := r.state = asEnabled;

  if (not r.success) and (r.action <> aaCheck) then
    ShowBalloon(r.errorMsg, '', bfError);
end;

procedure TfrmMain.miAutostartClick(Sender: TObject);
var
  flag: TAppFlag;
  action: TAutostartAction;
begin
  if FClosePending then
    exit;

  if miAutostart.Checked then
  begin
    flag := afAutostartDisable;
    action := aaDisable;
  end
  else
  begin
    flag := afAutostartEnable;
    action := aaEnable;
  end;

  if not IsProcessElevated then
  begin
    FDrover.PersistRuntimeState;
    if LaunchSelf(FlagsToCmdLine([flag, afRestart]), Handle) then
      Close;
    exit;
  end;

  StartAutostartThread(action);
end;

procedure TfrmMain.miHomepageClick(Sender: TObject);
begin
  ShellExecute(0, 'open', 'https://github.com/hdrover/sing-box-drover', nil, nil, SW_SHOWNORMAL);
end;

procedure TfrmMain.miRestartClick(Sender: TObject);
var
  flags: TAppFlags;
begin
  if FClosePending then
    exit;

  flags := [afRestart];
  if FIsTunActive then
    Include(flags, afTun);

  FDrover.PersistRuntimeState;
  if LaunchSelf(FlagsToCmdLine(flags), Handle, IsProcessElevated) then
    Close;
end;

procedure TfrmMain.InitDrover(ADrover: TDrover);
begin
  FDrover := ADrover;
  FDrover.NotifyHandle := Handle;

  DrawSelectors;

  miTun.Visible := FDrover.sbConfig.hasTunInbound;
  ToggleTunDisplay(FDrover.IsTunActive, false);

  if FDrover.Options.systemProxyAuto then
    ToggleSystemProxy(true, false);

  UpdateTrayIcon;

  TrayIcon.Visible := true;

  FDrover.OnEvent := HandleDroverEvent;
end;

procedure TfrmMain.HandleDroverEvent(event: TDroverEvent);
var
  pendingItem: TMenuItem;
  coreEvent: TCoreEvent;
begin
  case event.kind of
    dekError:
      ShowBalloon(event.msg, '', bfError);

    dekRunning:
      begin
        ToggleTunDisplay(FDrover.IsTunActive);
        miTun.Enabled := true;
      end;

    dekCoreEvent:
      begin
        coreEvent := event.coreEvent;
        case coreEvent.kind of
          cekSelectorDone:
            if FPendingSelectorRequests.TryGetValue(coreEvent.requestId, pendingItem) then
            begin
              FPendingSelectorRequests.Remove(coreEvent.requestId);
              pendingItem.Enabled := true;
            end;
        end;
      end;
  end;
end;

procedure TfrmMain.ShowBalloon(AText, ATitle: string; AFlags: TBalloonFlags = bfInfo; ATimeout: integer = 10000);
begin
  if (AFlags = bfError) and (ATitle = '') then
    ATitle := 'Error';

  TrayIcon.BalloonHint := AText;
  TrayIcon.BalloonTitle := ATitle;
  TrayIcon.BalloonFlags := AFlags;
  TrayIcon.BalloonTimeout := ATimeout;
  TrayIcon.ShowBalloonHint;
end;

procedure TfrmMain.DrawSelectors;
const
  AUTO_FLAT_ROWS_THRESHOLD = 20;
var
  selectors: TConfigSelectors;
  selector: TConfigSelector;
  outboundName: string;
  popupItems, selectorItem, outboundItem: TMenuItem;
  insertIndex, selectorCount, selectorI, outboundI: integer;
  flatRows: integer;
  isNested: boolean;
  itemOwner: TComponent;
begin
  selectors := FDrover.selectors;
  selectorCount := Length(selectors);
  if (selectorCount < 1) or (selectorCount > 50) then
    exit;

  case FDrover.Options.selectorMenuLayout of
    smlFlat:
      isNested := false;
    smlNested:
      isNested := true;
  else
    flatRows := 2 * selectorCount;
    for selectorI := Low(selectors) to High(selectors) do
      inc(flatRows, Length(selectors[selectorI].outbounds));
    isNested := flatRows > AUTO_FLAT_ROWS_THRESHOLD;
  end;

  popupItems := PopupMenu.Items;
  insertIndex := popupItems.IndexOf(miBeforeSelectors) + 1;
  selectorItem := nil;

  for selectorI := Low(selectors) to High(selectors) do
  begin
    selector := selectors[selectorI];

    selectorItem := TMenuItem.Create(popupItems);
    selectorItem.Caption := selector.name;

    if not isNested then
    begin
      selectorItem.Enabled := false;
      popupItems.Insert(insertIndex, selectorItem);
      inc(insertIndex);
    end;

    outboundItem := nil;
    if isNested then
      itemOwner := selectorItem
    else
      itemOwner := popupItems;

    for outboundI := Low(selector.outbounds) to High(selector.outbounds) do
    begin
      outboundName := selector.outbounds[outboundI];

      outboundItem := TMenuItem.Create(itemOwner);
      outboundItem.Caption := outboundName;
      outboundItem.AutoCheck := true;
      outboundItem.RadioItem := true;
      outboundItem.OnClick := miSelectorClick;
      outboundItem.Tag := selectorI * 1000 + outboundI;
      outboundItem.Checked := (outboundI = selector.defaultIndex);
      outboundItem.GroupIndex := selectorI + 10;

      if isNested then
      begin
        selectorItem.Add(outboundItem);
      end
      else
      begin
        popupItems.Insert(insertIndex, outboundItem);
        inc(insertIndex);
      end;
    end;

    if (not isNested) and Assigned(outboundItem) then
    begin
      popupItems.InsertNewLineAfter(outboundItem);
      inc(insertIndex);
    end;

    if isNested then
    begin
      popupItems.Insert(insertIndex, selectorItem);
      inc(insertIndex);
    end;
  end;

  if isNested then
  begin
    popupItems.InsertNewLineAfter(selectorItem);
  end;
end;

procedure TfrmMain.UpdateTrayIcon;
var
  s: string;
begin
  if FIsTunActive then
  begin
    s := 'TRAY_ICON_TUN';
  end
  else
  begin
    if FIsSystemProxyActive then
      s := 'TRAY_ICON'
    else
      s := 'TRAY_ICON_DISABLED';
  end;

  TrayIcon.Icon.LoadFromResourceName(HInstance, s);
  TrayIcon.Icon := TrayIcon.Icon;
end;

procedure TfrmMain.ToggleSystemProxy(AEnable: boolean; AUpdateTrayIcon: boolean = true);
begin
  if AEnable and FClosePending then
    exit;

  FIsSystemProxyActive := AEnable;
  miSystemProxy.Checked := AEnable;

  if AEnable then
    FDrover.EnableSystemProxy
  else
    FDrover.DisableSystemProxy;

  if AUpdateTrayIcon then
    UpdateTrayIcon;
end;

procedure TfrmMain.ToggleTunDisplay(AActive: boolean; AUpdateTrayIcon: boolean = true);
begin
  FIsTunActive := AActive;
  miTun.Checked := AActive;

  if AUpdateTrayIcon then
    UpdateTrayIcon;
end;

procedure TfrmMain.ToggleTun(AEnable: boolean);
begin
  if AEnable and FClosePending then
    exit;

  if not IsProcessElevated then
  begin
    FDrover.PersistRuntimeState;
    if LaunchSelf(FlagsToCmdLine([afTun, afRestart]), Handle) then
      Close;
    exit;
  end;

  ToggleTunDisplay(AEnable);
  miTun.Enabled := false;
  FDrover.StartCore(miTun.Checked);
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  if not Assigned(FDrover) then
  begin
    CanClose := true;
    exit;
  end;

  FClosePending := true;
  ShowOnlyExitInTray;

  ToggleTunDisplay(false, false);

  if FDrover.Options.systemProxyAuto then
    ToggleSystemProxy(false, false);

  UpdateTrayIcon;

  CanClose := FDrover.Shutdown;
end;

procedure TfrmMain.WMDroverCanClose(var msg: TMessage);
begin
  if not FClosePending then
    exit;

  EndMenu;
  PostMessage(Handle, WM_CLOSE, 0, 0);
end;

procedure TfrmMain.miQuitClick(Sender: TObject);
begin
  Close;
end;

procedure TfrmMain.miSystemProxyClick(Sender: TObject);
begin
  ToggleSystemProxy(not miSystemProxy.Checked);
end;

procedure TfrmMain.miTunClick(Sender: TObject);
begin
  ToggleTun(not miTun.Checked);
end;

procedure TfrmMain.TrayIconClick(Sender: TObject);
var
  shiftHeld: boolean;
begin
  shiftHeld := (GetKeyState(VK_SHIFT) and $8000) <> 0;

  if shiftHeld then
  begin
    if miTun.Visible and miTun.Enabled then
      ToggleTun(not FIsTunActive);
  end
  else
  begin
    if not FIsTunActive then
      ToggleSystemProxy(not FIsSystemProxyActive);
  end;
end;

procedure TfrmMain.miSelectorClick(Sender: TObject);
var
  item: TMenuItem;
  i: integer;
  selectorI, outboundI: integer;
  requestId: NativeInt;
begin
  if not(Sender is TMenuItem) then
    exit;

  item := TMenuItem(Sender);
  i := item.Tag;

  selectorI := i div 1000;
  outboundI := i mod 1000;

  item.Checked := true;

  requestId := NewRequestId;

  if not FDrover.EditSelector(selectorI, outboundI, requestId) then
    exit;

  FPendingSelectorRequests.Add(requestId, item);
  item.Enabled := false;
end;

procedure TfrmMain.ShowOnlyExitInTray;
begin
  for var item in PopupMenu.Items do
    item.Visible := (item = miQuit);
end;

end.
