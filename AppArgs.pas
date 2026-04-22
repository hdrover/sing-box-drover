unit AppArgs;

interface

type
  TAppFlag = (afTun, afElevatedRestart, afAutostartEnable, afAutostartDisable);
  TAppFlags = set of TAppFlag;

function GetAppFlags: TAppFlags;
function FlagsToCmdLine(const flags: TAppFlags): string;

implementation

uses
  System.SysUtils;

const
  FlagSwitches: array [TAppFlag] of string = ('tun', 'elevated-restart', 'autostart-enable', 'autostart-disable');

var
  GAppFlags: TAppFlags;

function ParseAppFlags: TAppFlags;
var
  flag: TAppFlag;
begin
  result := [];
  for flag := Low(TAppFlag) to High(TAppFlag) do
    if FindCmdLineSwitch(FlagSwitches[flag]) then
      Include(result, flag);
end;

function GetAppFlags: TAppFlags;
begin
  result := GAppFlags;
end;

function FlagsToCmdLine(const flags: TAppFlags): string;
var
  flag: TAppFlag;
begin
  result := '';
  for flag := Low(TAppFlag) to High(TAppFlag) do
    if flag in flags then
    begin
      if result <> '' then
        result := result + ' ';
      result := result + '-' + FlagSwitches[flag];
    end;
end;

initialization

GAppFlags := ParseAppFlags;

end.
