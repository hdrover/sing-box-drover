unit Main;

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.ExtCtrls, Vcl.Menus, System.Net.HttpClient,
  System.Net.URLClient, System.JSON, System.IOUtils, System.Generics.Collections, Options, Drover;

type
  TfrmMain = class(TForm)
    PopupMenu: TPopupMenu;
    miQuit: TMenuItem;
    miSystemProxy: TMenuItem;
    miBeforeSelectors: TMenuItem;
    miTun: TMenuItem;
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure miQuitClick(Sender: TObject);
    procedure miSystemProxyClick(Sender: TObject);
    procedure TrayIconClick(Sender: TObject);
    procedure miSelectorClick(Sender: TObject);
    procedure DrawSelectors;
    procedure FormCreate(Sender: TObject);
    procedure miTunClick(Sender: TObject);
  private
    TrayIcon: TTrayIcon;
    FDrover: TDrover;
    FIsTunActive: boolean;
    FIsSystemProxyActive: boolean;
    FClosePending: boolean;

    procedure UpdateTrayIcon;
    procedure ToggleSystemProxy(AEnable: boolean; AUpdateTrayIcon: boolean = true);
    procedure ToggleTunDisplay(AActive: boolean; AUpdateTrayIcon: boolean = true);
    procedure ToggleTun(AEnable: boolean);
    procedure HandleDroverEvent(event: TDroverEvent);
    procedure WMDroverCanClose(var msg: TMessage); message WM_DROVER_CAN_CLOSE;
    procedure ShowBalloon(AText, ATitle: string; AFlags: TBalloonFlags = bfInfo; ATimeout: integer = 10000);
    procedure ShowOnlyExitInTray;
  public

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

  miTun.Enabled := false;
  miTun.Visible := false;

  TrayIcon := TTrayIcon.Create(self);
  TrayIcon.PopupMenu := PopupMenu;
  TrayIcon.OnClick := TrayIconClick;
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
begin
  case event.kind of
    dekError:
      ShowBalloon(event.msg, '', bfError);

    dekRunning:
      begin
        ToggleTunDisplay(FDrover.IsTunActive);
        miTun.Enabled := FDrover.IsAdmin;
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
var
  selectors: TConfigSelectors;
  selector: TConfigSelector;
  outboundName: string;
  popupItems, selectorItem, outboundItem: TMenuItem;
  insertIndex, selectorCount, selectorI, outboundI: integer;
  isNested: boolean;
  itemOwner: TComponent;
begin
  selectors := FDrover.sbConfig.selectors;
  selectorCount := Length(selectors);
  if (selectorCount < 1) or (selectorCount > 50) then
    exit;

  isNested := FDrover.Options.selectorMenuLayout = 'nested';

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
      Inc(insertIndex);
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
      outboundItem.Checked := (outboundI = selector.default);
      outboundItem.GroupIndex := selectorI + 10;

      if isNested then
      begin
        selectorItem.Add(outboundItem);
      end
      else
      begin
        popupItems.Insert(insertIndex, outboundItem);
        Inc(insertIndex);
      end;
    end;

    if (not isNested) and Assigned(outboundItem) then
    begin
      popupItems.InsertNewLineAfter(outboundItem);
      Inc(insertIndex);
    end;

    if isNested then
    begin
      popupItems.Insert(insertIndex, selectorItem);
      Inc(insertIndex);
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
begin
  ToggleSystemProxy(not FIsSystemProxyActive);
end;

procedure TfrmMain.miSelectorClick(Sender: TObject);
var
  selectors: TConfigSelectors;
  item: TMenuItem;
  i: integer;
  selectorI, outboundI: integer;
  selector: TConfigSelector;
  outboundName: string;
begin
  if not(Sender is TMenuItem) then
    exit;

  item := TMenuItem(Sender);
  i := item.Tag;

  selectorI := i div 1000;
  outboundI := i mod 1000;

  selectors := FDrover.sbConfig.selectors;

  if (selectorI < Low(selectors)) or (selectorI > High(selectors)) then
    exit;
  selector := selectors[selectorI];
  if (outboundI < Low(selector.outbounds)) or (outboundI > High(selector.outbounds)) then
    exit;
  outboundName := selector.outbounds[outboundI];

  item.Checked := true;

  FDrover.EditSelector(selector.name, outboundName);
end;

procedure TfrmMain.ShowOnlyExitInTray;
begin
  for var item in PopupMenu.Items do
    item.Visible := (item = miQuit);
end;

end.
