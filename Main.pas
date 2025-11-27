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
  private
    TrayIcon: TTrayIcon;
    FDrover: TDrover;
    isSystemProxyEnabled: boolean;
  public

    procedure InitDrover(Drover: TDrover);
  end;

var
  frmMain: TfrmMain;

implementation

{$R *.dfm}

procedure TfrmMain.InitDrover(Drover: TDrover);
begin
  FDrover := Drover;

  isSystemProxyEnabled := false;

  DrawSelectors();

  TrayIcon := TTrayIcon.Create(self);
  TrayIcon.PopupMenu := PopupMenu;
  TrayIcon.OnClick := TrayIconClick;

  if FDrover.Options.systemProxyAuto then
    ToggleSystemProxy(true)
  else
    ToggleSystemProxyIcon(false);

  TrayIcon.Visible := true;
end;

procedure TfrmMain.DrawSelectors;
var
  selectors: TConfigSelectors;
  selector: TConfigSelector;
  outboundName: string;
  popupItems, selectorItem, outboundItem: TMenuItem;
  prevIndex: integer;
  selectorI, outboundI: integer;
begin
  selectors := FDrover.sbConfig.selectors;
  if Length(selectors) < 1 then
    exit;

  popupItems := PopupMenu.Items;
  prevIndex := popupItems.IndexOf(miBeforeSelectors);
  selectorItem := nil;

  for selectorI := Low(selectors) to High(selectors) do
  begin
    selector := selectors[selectorI];

    selectorItem := TMenuItem.Create(popupItems);
    selectorItem.Caption := selector.name;

    for outboundI := Low(selector.outbounds) to High(selector.outbounds) do
    begin
      outboundName := selector.outbounds[outboundI];

      outboundItem := TMenuItem.Create(selectorItem);
      outboundItem.Caption := outboundName;
      outboundItem.AutoCheck := true;
      outboundItem.RadioItem := true;
      outboundItem.OnClick := miSelectorClick;
      outboundItem.Tag := selectorI * 1000 + outboundI;
      outboundItem.Checked := (outboundI = selector.default);

      selectorItem.Add(outboundItem);
    end;

    popupItems.Insert(prevIndex + 1, selectorItem);
    prevIndex := popupItems.IndexOf(selectorItem);
  end;

  if selectorItem <> nil then
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
  if FDrover.Options.systemProxyAuto then
    ToggleSystemProxy(false);
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
