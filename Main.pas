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
    procedure FormCloseQuery(Sender: TObject; var CanClose: boolean);
    procedure miQuitClick(Sender: TObject);
    procedure PopupMenuPopup(Sender: TObject);
    procedure miSystemProxyClick(Sender: TObject);
    procedure TrayIconClick(Sender: TObject);
    procedure miSelectorClick(Sender: TObject);
    procedure DrawSelectors;
    procedure ToggleSystemProxyIcon(enable: boolean);
    procedure ToggleSystemProxy(enable: boolean);
    procedure FormCreate(Sender: TObject);
  private
    TrayIcon: TTrayIcon;
    FDrover: TDrover;
    isSystemProxyEnabled: boolean;
    FClosePending: boolean;

    procedure HandleDroverEvent(event: TDroverEvent);
    procedure WMDroverCanClose(var msg: TMessage); message WM_DROVER_CAN_CLOSE;
    procedure ShowBalloon(AText, ATitle: string; AFlags: TBalloonFlags = bfInfo; ATimeout: integer = 10000);
  public

    procedure InitDrover(ADrover: TDrover);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

procedure TfrmMain.FormCreate(Sender: TObject);
begin
  FClosePending := false;
  isSystemProxyEnabled := false;

  TrayIcon := TTrayIcon.Create(self);
  TrayIcon.PopupMenu := PopupMenu;
  TrayIcon.OnClick := TrayIconClick;
  TrayIcon.Visible := true;
end;

procedure TfrmMain.InitDrover(ADrover: TDrover);
begin
  FDrover := ADrover;
  FDrover.NotifyHandle := Handle;
  FDrover.OnEvent := HandleDroverEvent;

  DrawSelectors;

  if FDrover.Options.systemProxyAuto then
    ToggleSystemProxy(true)
  else
    ToggleSystemProxyIcon(false);
end;

procedure TfrmMain.HandleDroverEvent(event: TDroverEvent);
begin
  case event.kind of
    dekError:
      ShowBalloon(event.msg, '', bfError);
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

procedure TfrmMain.ToggleSystemProxyIcon(enable: boolean);
var
  s: string;
begin
  if enable then
    s := 'TRAY_ICON'
  else
    s := 'TRAY_ICON_DISABLED';
  TrayIcon.Icon.LoadFromResourceName(HInstance, s);
  TrayIcon.Icon := TrayIcon.Icon;
end;

procedure TfrmMain.ToggleSystemProxy(enable: boolean);
begin
  isSystemProxyEnabled := enable;

  if enable then
    FDrover.EnableSystemProxy
  else
    FDrover.DisableSystemProxy;

  ToggleSystemProxyIcon(enable);
end;

procedure TfrmMain.FormCloseQuery(Sender: TObject; var CanClose: boolean);
begin
  if not Assigned(FDrover) then
  begin
    CanClose := true;
    exit;
  end;

  if FDrover.Options.systemProxyAuto then
    ToggleSystemProxy(false);

  CanClose := FDrover.Shutdown;

  if not CanClose then
  begin
    FClosePending := true;
  end;
end;

procedure TfrmMain.WMDroverCanClose(var msg: TMessage);
begin
  if not FClosePending then
    exit;
  FClosePending := false;
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

procedure TfrmMain.PopupMenuPopup(Sender: TObject);
begin
  miSystemProxy.Checked := isSystemProxyEnabled;
end;

procedure TfrmMain.TrayIconClick(Sender: TObject);
begin
  ToggleSystemProxy(not isSystemProxyEnabled);
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

end.
