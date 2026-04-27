object frmMain: TfrmMain
  Left = 0
  Top = 0
  Caption = 'sing-box-drover'
  ClientHeight = 278
  ClientWidth = 412
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  TextHeight = 15
  object PopupMenu: TPopupMenu
    Left = 248
    Top = 40
    object miExtras: TMenuItem
      Caption = 'Extras'
      object miRestart: TMenuItem
        Caption = 'Restart'
        OnClick = miRestartClick
      end
      object miAutostart: TMenuItem
        Caption = 'Autostart'
        Enabled = False
        OnClick = miAutostartClick
      end
      object miHomepage: TMenuItem
        Caption = 'GitHub'
        OnClick = miHomepageClick
      end
    end
    object miTun: TMenuItem
      Caption = 'TUN mode'
      Visible = False
      OnClick = miTunClick
    end
    object miSystemProxy: TMenuItem
      Caption = 'System proxy'
      OnClick = miSystemProxyClick
    end
    object miBeforeSelectors: TMenuItem
      Caption = '-'
    end
    object miQuit: TMenuItem
      Caption = 'Quit'
      OnClick = miQuitClick
    end
  end
end
