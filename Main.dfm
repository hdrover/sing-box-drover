object frmMain: TfrmMain
  Left = 0
  Top = 0
  Margins.Left = 6
  Margins.Top = 6
  Margins.Right = 6
  Margins.Bottom = 6
  Caption = 'sing-box-drover'
  ClientHeight = 572
  ClientWidth = 829
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -24
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  PixelsPerInch = 192
  TextHeight = 32
  object PopupMenu: TPopupMenu
    OnPopup = PopupMenuPopup
    Left = 248
    Top = 40
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
