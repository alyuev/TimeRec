unit umain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Menus, Graphics,
  LCLType, LMessages, Dialogs, Windows;

type
  TMainForm = class(TForm)
    btnStartStop: TButton;
    cbTask: TComboBox;
    lblClock: TLabel;
    lblElapsed: TLabel;
    miStats: TMenuItem;
    miEdit: TMenuItem;
    miHideFromTaskBar: TMenuItem;
    miTopMost: TMenuItem;
    miOpacity: TMenuItem;
    miOp100: TMenuItem;
    miOp90: TMenuItem;
    miOp75: TMenuItem;
    miOp50: TMenuItem;
    miOp25: TMenuItem;
    miSep1: TMenuItem;
    miExit: TMenuItem;
    PopupMenu1: TPopupMenu;
    Timer1: TTimer;
    DeselTimer: TTimer;
    TrayIcon1: TTrayIcon;
    procedure btnStartStopClick(Sender: TObject);
    procedure cbTaskChange(Sender: TObject);
    procedure cbTaskDropDown(Sender: TObject);
    procedure cbTaskKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure cbTaskSelect(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure FormResize(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure miEditClick(Sender: TObject);
    procedure miExitClick(Sender: TObject);
    procedure miHideFromTaskBarClick(Sender: TObject);
    procedure miOpacityClick(Sender: TObject);
    procedure miStatsClick(Sender: TObject);
    procedure miTopMostClick(Sender: TObject);
    procedure Timer1Timer(Sender: TObject);
    procedure DeselTimerTimer(Sender: TObject);
    procedure TrayIcon1DblClick(Sender: TObject);
  private
    FRunning: Boolean;
    FTaskStart: TDateTime;
    FCurrentTask: string;
    FDataDir: string;
    FTasksFile: string;
    FConfigFile: string;
    FAllTasks: TStringList;
    FFiltering: Boolean;
    FProgrammaticDrop: Boolean;
    FItemsAreFiltered: Boolean;
    FJustSelected: Boolean;
    FJustPickedFromList: Boolean;
    FHighlightedIdx: Integer;
    FCurrentMarker: string;
    FLastAlive: TDateTime;
    FOpacity: Integer;
    procedure StartTask;
    procedure StopTask;
    procedure WriteCurrentMarker;
    procedure UpdateCurrentMarker;
    procedure DeleteCurrentMarker;
    procedure RecoverOrphanedTask;
    procedure LoadTaskHistory;
    procedure SaveTaskToHistory(const ATask: string);
    procedure AppendEntry(const ATask: string; AStart, AEnd: TDateTime);
    function TodayLogFile: string;
    procedure LoadConfig;
    procedure SaveConfig;
    procedure ApplyComboFilter;
    procedure RestoreFullList;
    procedure ApplyHideFromTaskBar;
    procedure ApplyTopMost;
    procedure ApplyOpacity(APercent: Integer);
    procedure DeselectCombo(Data: PtrInt);
    procedure ClearComboSelection(Data: PtrInt);
    procedure DeferredStartFromEnter(Data: PtrInt);
    procedure DeferredFocusStart(Data: PtrInt);
  protected
    procedure WndProc(var Message: TLMessage); override;
  public
  end;

var
  MainForm: TMainForm;

implementation

uses
  LazFileUtils, LCLIntf, DOM, XMLRead, XMLWrite, LazUTF8, ustats, uedit;

{$R *.lfm}

const
  TimeFmt = 'hh:nn:ss';
  IsoFmt  = 'yyyy"-"mm"-"dd"T"hh":"nn":"ss';

function AppDir: string;
begin
  Result := ExtractFilePath(Application.ExeName);
end;

procedure EnsureDir(const D: string);
begin
  if not DirectoryExists(D) then
    ForceDirectories(D);
end;

procedure InstallSubclass(h: HWND); forward;
procedure SubclassComboEdit(ComboHwnd: HWND); forward;

procedure TMainForm.FormCreate(Sender: TObject);
var
  IcoPath: string;
begin
  FDataDir := AppDir + 'data';
  EnsureDir(FDataDir);
  FTasksFile := FDataDir + PathDelim + 'tasks.xml';
  FConfigFile := AppDir + 'config.xml';
  FCurrentMarker := FDataDir + PathDelim + 'current.xml';
  FAllTasks := TStringList.Create;
  FAllTasks.Duplicates := dupIgnore;
  FAllTasks.Sorted := False;
  FRunning := False;
  FOpacity := 100;
  FHighlightedIdx := -1;
  LoadTaskHistory;
  RecoverOrphanedTask;
  LoadConfig;
  Timer1Timer(nil);

  IcoPath := AppDir + 'TimeRec.ico';
  if FileExists(IcoPath) then
  begin
    try
      Application.Icon.LoadFromFile(IcoPath);
      TrayIcon1.Icon.LoadFromFile(IcoPath);
    except
    end;
  end;
  if TrayIcon1.Icon.Empty then
    TrayIcon1.Icon.Assign(Application.Icon);
  TrayIcon1.Hint := 'TimeRec';
  TrayIcon1.Visible := True;

  // Apply config-driven window flags AFTER handle exists
  ApplyTopMost;
  if miHideFromTaskBar.Checked then
    ApplyHideFromTaskBar;

  // Install Win32 subclass: enables borderless edge resize via SC_SIZE
  InstallSubclass(Handle);
  FormResize(nil);

  // Reflect persisted opacity into menu + apply
  case FOpacity of
     90: miOp90.Checked := True;
     75: miOp75.Checked := True;
     50: miOp50.Checked := True;
     25: miOp25.Checked := True;
  else
    miOp100.Checked := True;
  end;
  ApplyOpacity(FOpacity);
end;

procedure TMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if FRunning then
    StopTask;
  SaveConfig;
  FAllTasks.Free;
end;

procedure TMainForm.FormMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
const
  WM_NCLBUTTONDOWN = $00A1;
begin
  if Button = mbLeft then
  begin
    ReleaseCapture;
    SendMessage(Self.Handle, WM_NCLBUTTONDOWN, HTCAPTION, 0);
  end;
end;

procedure TMainForm.FormShow(Sender: TObject);
begin
  // By OnShow the combo's inner Edit handle exists. Subclass it now so
  // arrow/Enter handling is in place before any user input. The helper is
  // idempotent (no-op if already installed).
  if cbTask.HandleAllocated then
    SubclassComboEdit(cbTask.Handle);
end;

procedure TMainForm.FormResize(Sender: TObject);
const
  BaseH = 32;
  FontBase = 11;
var
  S: Double;
  NewFont: Integer;
begin
  if not HandleAllocated then Exit;
  S := Height / BaseH;
  NewFont := -Round(FontBase * S);
  // Form font (cbTask + btnStartStop inherit through ParentFont)
  Font.Height := NewFont;
  // Labels have their own font settings — scale explicitly
  lblClock.Font.Height := NewFont;
  lblClock.SetBounds(Round(4 * S),  Round(2  * S), Round(46 * S), Round(13 * S));
  lblElapsed.Font.Height := NewFont;
  lblElapsed.SetBounds(Round(4 * S), Round(16 * S), Round(46 * S), Round(13 * S));
  cbTask.SetBounds(Round(54 * S),  Round(5 * S), Round(190 * S), Round(21 * S));
  btnStartStop.SetBounds(Round(248 * S), Round(4 * S), Round(52 * S), Round(24 * S));
  // Resizing the combo can leave its edit with a selection highlight —
  // schedule a deselect after the event chain settles.
  Application.QueueAsyncCall(@DeselectCombo, 0);
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
begin
  lblClock.Caption := FormatDateTime(TimeFmt, Now);
  if FRunning then
  begin
    lblElapsed.Caption := FormatDateTime(TimeFmt, Now - FTaskStart);
    if (Now - FLastAlive) * 86400 > 10 then
      UpdateCurrentMarker;
  end
  else
    lblElapsed.Caption := '00:00:00';
end;

{ -------- borderless resize support via subclassing -------- }
//
// We need Windows to act on HTLEFT/RIGHT/TOP/BOTTOM return values, which only
// happens when WS_THICKFRAME is on the window. LCL strips it for bsNone forms,
// and CreateParams overrides get post-processed away. So we attach a Win32
// subclass procedure directly to the form's HWND, set WS_THICKFRAME after the
// handle exists, and suppress the visual frame via WM_NCCALCSIZE.

var
  GOldWndProc: Pointer = nil;
  GMainHwnd: HWND = 0;
  GComboEdit: HWND = 0;
  GOldEditWndProc: Pointer = nil;
  GSuppressEditSel: Boolean = False;

const
  EM_SETSEL_ = $00B1;
  LB_GETCURSEL_  = $0188;
  LB_SETCURSEL_  = $0186;
  LB_GETCOUNT_   = $018B;
  CB_GETDROPPEDSTATE_ = $0157;
  CB_SETCURSEL_       = $014E;
  CB_SHOWDROPDOWN_    = $014F;

  WM_APP_FOCUS_START  = $8000 + 1;

var
  GHighlightedIdx: Integer = -1;

type
  TComboBoxInfo_ = packed record
    cbSize: DWORD;
    rcItem, rcButton: TRect;
    stateButton: DWORD;
    hwndCombo, hwndItem, hwndList: HWND;
  end;

function GetComboBoxInfoApi(hwndCombo: HWND; var Info: TComboBoxInfo_): BOOL;
  stdcall; external 'user32.dll' name 'GetComboBoxInfo';

function EditSubProc(h: HWND; uMsg: UINT; wParam: WPARAM;
  lParam: LPARAM): LRESULT; stdcall;
var
  cbi: TComboBoxInfo_;
  Combo: HWND;
  cur, cnt, newIdx: Integer;
begin
  if uMsg = WM_KEYDOWN then
  begin
    Combo := GetParent(h);
    if Combo <> 0 then
    case wParam of
      VK_DOWN, VK_UP:
        if SendMessage(Combo, CB_GETDROPPEDSTATE_, 0, 0) <> 0 then
        begin
          cbi.cbSize := SizeOf(cbi);
          if GetComboBoxInfoApi(Combo, cbi) and (cbi.hwndList <> 0) then
          begin
            cur := SendMessage(cbi.hwndList, LB_GETCURSEL_, 0, 0);
            cnt := SendMessage(cbi.hwndList, LB_GETCOUNT_,  0, 0);
            if wParam = VK_DOWN then newIdx := cur + 1
                                else newIdx := cur - 1;
            if newIdx < 0    then newIdx := 0;
            if newIdx >= cnt then newIdx := cnt - 1;
            if (cnt > 0) and (newIdx <> cur) then
            begin
              SendMessage(cbi.hwndList, LB_SETCURSEL_, newIdx, 0);
              GHighlightedIdx := newIdx;
            end;
          end;
          Exit(0); // swallow — don't let default copy item text into edit
        end;
      VK_RETURN:
        if SendMessage(Combo, CB_GETDROPPEDSTATE_, 0, 0) <> 0 then
        begin
          if GHighlightedIdx >= 0 then
          begin
            SendMessage(Combo, CB_SETCURSEL_, GHighlightedIdx, 0);
            GHighlightedIdx := -1;
          end;
          SendMessage(Combo, CB_SHOWDROPDOWN_, 0, 0);
          // Move focus to Start button — deferred so Enter doesn't click it
          if GMainHwnd <> 0 then
            PostMessage(GMainHwnd, WM_APP_FOCUS_START, 0, 0);
          Exit(0);
        end;
    end;
  end;
  if (uMsg = EM_SETSEL_) and GSuppressEditSel and (wParam <> lParam) then
  begin
    Result := CallWindowProc(GOldEditWndProc, h, uMsg, 0, 0);
    Exit;
  end;
  Result := CallWindowProc(GOldEditWndProc, h, uMsg, wParam, lParam);
end;

var
  GFoundEdit: HWND = 0;

function FindEditEnumProc(h: HWND; l: LPARAM): BOOL; stdcall;
var
  sb: array[0..31] of Char;
begin
  Result := True;
  if GetClassName(h, sb, SizeOf(sb)) > 0 then
    if (StrComp(sb, 'Edit') = 0) or (StrComp(sb, 'EDIT') = 0) then
    begin
      GFoundEdit := h;
      Result := False;
    end;
end;

procedure SubclassComboEdit(ComboHwnd: HWND);
begin
  GFoundEdit := 0;
  EnumChildWindows(ComboHwnd, @FindEditEnumProc, 0);
  if (GFoundEdit = 0) or (GComboEdit = GFoundEdit) then Exit;
  GComboEdit := GFoundEdit;
  GOldEditWndProc := Pointer(GetWindowLongPtr(GComboEdit, GWL_WNDPROC));
  SetWindowLongPtr(GComboEdit, GWL_WNDPROC, PtrInt(@EditSubProc));
end;

function HTCodeFromEdges(L, R, T, B: Boolean): Integer;
begin
  if L and T then Exit(HTTOPLEFT);
  if R and T then Exit(HTTOPRIGHT);
  if L and B then Exit(HTBOTTOMLEFT);
  if R and B then Exit(HTBOTTOMRIGHT);
  if L then Exit(HTLEFT);
  if R then Exit(HTRIGHT);
  if T then Exit(HTTOP);
  if B then Exit(HTBOTTOM);
  Result := HTCLIENT;
end;

function NewWndProc(h: HWND; uMsg: UINT; wParam: WPARAM;
  lParam: LPARAM): LRESULT; stdcall;
const
  EdgePx = 4;
  BaseW = 304;
  BaseH = 32;
  AspectRatio: Double = BaseW / BaseH;
  SC_SIZE_CMD = $F000;
var
  Pt: TPoint;
  WR: TRect;
  L_, R_, T_, B_: Boolean;
  W, Hgt: Integer;
  SR: PRect;
  WP: PtrUInt;
  HT: Integer;
begin
  case uMsg of
    WM_NCHITTEST:
      begin
        Pt.X := SmallInt(lParam and $FFFF);
        Pt.Y := SmallInt((lParam shr 16) and $FFFF);
        GetWindowRect(h, WR);
        Dec(Pt.X, WR.Left);
        Dec(Pt.Y, WR.Top);
        W := WR.Right - WR.Left;
        Hgt := WR.Bottom - WR.Top;
        L_ := Pt.X < EdgePx;
        R_ := Pt.X >= W - EdgePx;
        T_ := Pt.Y < EdgePx;
        B_ := Pt.Y >= Hgt - EdgePx;
        Result := HTCodeFromEdges(L_, R_, T_, B_);
        if Result <> HTCLIENT then Exit;
        // Interior: let LCL handle (right-click popup, drag via OnMouseDown).
      end;

    WM_SETCURSOR:
      begin
        // LOWORD(lParam) holds the hit-test code from the most recent
        // WM_NCHITTEST. LCL's default handler resets the cursor to arrow,
        // so we must claim ownership for edge zones.
        HT := Integer(lParam) and $FFFF;
        case HT of
          HTLEFT, HTRIGHT:
            begin SetCursor(LoadCursor(0, IDC_SIZEWE));   Exit(1); end;
          HTTOP, HTBOTTOM:
            begin SetCursor(LoadCursor(0, IDC_SIZENS));   Exit(1); end;
          HTTOPLEFT, HTBOTTOMRIGHT:
            begin SetCursor(LoadCursor(0, IDC_SIZENWSE)); Exit(1); end;
          HTTOPRIGHT, HTBOTTOMLEFT:
            begin SetCursor(LoadCursor(0, IDC_SIZENESW)); Exit(1); end;
        end;
      end;

    WM_NCLBUTTONDOWN:
      begin
        HT := Integer(wParam);
        if (HT >= HTLEFT) and (HT <= HTBOTTOMRIGHT) then
        begin
          // Initiate Windows' modal sizing loop. SC_SIZE direction codes
          // (1..8) map directly from HT codes minus 9.
          ReleaseCapture;
          SendMessage(h, WM_SYSCOMMAND, SC_SIZE_CMD + (HT - HTLEFT + 1), lParam);
          Exit(0);
        end;
      end;

    WM_SIZING:
      begin
        SR := PRect(lParam);
        WP := wParam;
        W := SR^.Right - SR^.Left;
        Hgt := SR^.Bottom - SR^.Top;
        case WP of
          WMSZ_TOP, WMSZ_BOTTOM:
            W := Round(Hgt * AspectRatio);
          else
            Hgt := Round(W / AspectRatio);
        end;
        if Hgt < BaseH then begin Hgt := BaseH; W := BaseW; end;
        case WP of
          WMSZ_LEFT, WMSZ_TOPLEFT, WMSZ_BOTTOMLEFT: SR^.Left := SR^.Right - W;
          else SR^.Right := SR^.Left + W;
        end;
        case WP of
          WMSZ_TOP, WMSZ_TOPLEFT, WMSZ_TOPRIGHT: SR^.Top := SR^.Bottom - Hgt;
          else SR^.Bottom := SR^.Top + Hgt;
        end;
        Exit(1);
      end;

    WM_WINDOWPOSCHANGING:
      if Assigned(MainForm) and MainForm.miTopMost.Checked then
      begin
        if (PWindowPos(lParam)^.flags and SWP_NOZORDER) = 0 then
          PWindowPos(lParam)^.hwndInsertAfter := HWND_TOPMOST;
      end;
  end;
  Result := CallWindowProc(GOldWndProc, h, uMsg, wParam, lParam);
end;

procedure InstallSubclass(h: HWND);
begin
  if (h = 0) or (GMainHwnd = h) then Exit;
  GMainHwnd := h;
  GOldWndProc := Pointer(GetWindowLongPtr(h, GWL_WNDPROC));
  SetWindowLongPtr(h, GWL_WNDPROC, PtrInt(@NewWndProc));
end;

procedure TMainForm.WndProc(var Message: TLMessage);
begin
  // Custom message from edit subclass: focus the Start button.
  if Message.Msg = WM_APP_FOCUS_START then
  begin
    if btnStartStop.CanFocus then btnStartStop.SetFocus;
    Exit;
  end;
  // Top-most enforcement is the only thing we still need at LCL level —
  // NC sizing and hit-testing are handled by the Win32 subclass above.
  if (Message.Msg = LM_WINDOWPOSCHANGING) and miTopMost.Checked then
  begin
    if (PWindowPos(Message.LParam)^.flags and SWP_NOZORDER) = 0 then
      PWindowPos(Message.LParam)^.hwndInsertAfter := HWND_TOPMOST;
  end;
  inherited WndProc(Message);
end;

procedure TMainForm.btnStartStopClick(Sender: TObject);
begin
  if FRunning then
    StopTask
  else
    StartTask;
end;

procedure TMainForm.StartTask;
var
  T: string;
begin
  T := Trim(cbTask.Text);
  if T = '' then
  begin
    ShowMessage('Введите название задачи');
    cbTask.SetFocus;
    Exit;
  end;
  FCurrentTask := T;
  FTaskStart := Now;
  FRunning := True;
  btnStartStop.Caption := 'Stop';
  cbTask.Enabled := False;
  SaveTaskToHistory(T);
  WriteCurrentMarker;
end;

procedure TMainForm.StopTask;
var
  EndTime: TDateTime;
begin
  if not FRunning then Exit;
  EndTime := Now;
  AppendEntry(FCurrentTask, FTaskStart, EndTime);
  DeleteCurrentMarker;
  FRunning := False;
  btnStartStop.Caption := 'Start';
  cbTask.Enabled := True;
  lblElapsed.Caption := '00:00:00';
end;

{ -------- crash-safe marker -------- }

procedure TMainForm.WriteCurrentMarker;
var
  Doc: TXMLDocument;
  Root: TDOMElement;
begin
  Doc := TXMLDocument.Create;
  try
    Root := Doc.CreateElement('current');
    Doc.AppendChild(Root);
    Root.SetAttribute('task',      FCurrentTask);
    Root.SetAttribute('start',     FormatDateTime(IsoFmt, FTaskStart));
    Root.SetAttribute('lastAlive', FormatDateTime(IsoFmt, Now));
    WriteXMLFile(Doc, FCurrentMarker);
  finally
    Doc.Free;
  end;
  FLastAlive := Now;
end;

procedure TMainForm.UpdateCurrentMarker;
begin
  WriteCurrentMarker;
end;

procedure TMainForm.DeleteCurrentMarker;
begin
  if FileExists(FCurrentMarker) then
    SysUtils.DeleteFile(FCurrentMarker);
end;

procedure TMainForm.RecoverOrphanedTask;
var
  Doc: TXMLDocument;
  Root: TDOMElement;
  TaskS, StartS, AliveS: string;
  StartDT, AliveDT: TDateTime;

  function TryParseIso(const S: string; out DT: TDateTime): Boolean;
  var Y, Mo, D, H, Mi, Se: Integer;
  begin
    Result := False;
    if Length(S) < 19 then Exit;
    try
      Y  := StrToInt(Copy(S, 1, 4));
      Mo := StrToInt(Copy(S, 6, 2));
      D  := StrToInt(Copy(S, 9, 2));
      H  := StrToInt(Copy(S, 12, 2));
      Mi := StrToInt(Copy(S, 15, 2));
      Se := StrToInt(Copy(S, 18, 2));
      DT := EncodeDate(Y, Mo, D) + EncodeTime(H, Mi, Se, 0);
      Result := True;
    except
    end;
  end;

begin
  if not FileExists(FCurrentMarker) then Exit;
  Doc := nil;
  try
    try
      ReadXMLFile(Doc, FCurrentMarker);
      Root := Doc.DocumentElement;
      TaskS  := Root.GetAttribute('task');
      StartS := Root.GetAttribute('start');
      AliveS := Root.GetAttribute('lastAlive');
      if (TaskS <> '') and TryParseIso(StartS, StartDT)
         and TryParseIso(AliveS, AliveDT) and (AliveDT >= StartDT) then
      begin
        AppendEntry(TaskS, StartDT, AliveDT);
        TrayIcon1.BalloonTitle := 'TimeRec';
        TrayIcon1.BalloonHint :=
          'Восстановлена незавершённая задача: ' + TaskS + LineEnding +
          'Длительность: ' + FormatDateTime(TimeFmt, AliveDT - StartDT);
      end;
    except
    end;
  finally
    Doc.Free;
    DeleteCurrentMarker;
  end;
end;

{ -------- ComboBox substring filter -------- }

procedure TMainForm.cbTaskChange(Sender: TObject);
begin
  if FFiltering then Exit;
  // Detect "user picked an item from the dropdown" robustly:
  // OnChange may fire before OnSelect, so the flag alone isn't enough.
  // But by the time OnChange runs, ItemIndex already points at the picked
  // row and Text equals that row's caption — that's the real signal.
  if (cbTask.ItemIndex >= 0) and (cbTask.ItemIndex < cbTask.Items.Count)
     and (cbTask.Items[cbTask.ItemIndex] = cbTask.Text) then
  begin
    FJustSelected := False;
    // Arrow-key navigation in the open dropdown also lands here and the
    // combobox auto-selects the new text in the edit — clear it without
    // moving focus, so the user can keep navigating.
    Application.QueueAsyncCall(@ClearComboSelection, 0);
    Exit;
  end;
  if FJustSelected then
  begin
    FJustSelected := False;
    Exit;
  end;
  if UTF8Length(cbTask.Text) >= 3 then
    ApplyComboFilter
  else
    RestoreFullList;
end;

procedure TMainForm.cbTaskSelect(Sender: TObject);
begin
  FJustSelected := True;
  FJustPickedFromList := True;
  // The blue highlight is just the focused edit's selection rendering —
  // moving focus to the Start button hides it instantly. Use a timer with
  // 100 ms delay so we run AFTER Windows finishes restoring focus to the
  // combo's edit at the end of its CBN_SELCHANGE sequence.
  DeselTimer.Enabled := False;
  DeselTimer.Enabled := True;
end;

procedure TMainForm.DeselTimerTimer(Sender: TObject);
begin
  DeselTimer.Enabled := False;
  DeselectCombo(0);
end;

procedure TMainForm.DeselectCombo(Data: PtrInt);
const
  CB_SETEDITSEL = $0142;
begin
  // After dropdown selection: clear selection AND move focus off so the
  // edit no longer paints the highlight.
  if cbTask.HandleAllocated then
    SendMessage(cbTask.Handle, CB_SETEDITSEL, 0, 0);
  if btnStartStop.CanFocus then
    btnStartStop.SetFocus;
end;

procedure TMainForm.ClearComboSelection(Data: PtrInt);
const
  CB_SETEDITSEL = $0142;
  L = $FFFFFFFF;
begin
  // Clear the edit selection without moving focus — used during arrow-key
  // navigation in the open dropdown. lParam = -1 removes the selection.
  if cbTask.HandleAllocated then
    SendMessage(cbTask.Handle, CB_SETEDITSEL, 0, L);
end;

procedure TMainForm.cbTaskDropDown(Sender: TObject);
begin
  // Reset highlight tracking for the new dropdown session
  GHighlightedIdx := -1;
  FHighlightedIdx := -1;
  // Lazy-subclass the inner Edit on first dropdown — it exists by now.
  if (GComboEdit = 0) and cbTask.HandleAllocated then
    SubclassComboEdit(cbTask.Handle);
  if FProgrammaticDrop then
  begin
    FProgrammaticDrop := False;
    Exit;
  end;
  RestoreFullList;
end;

type
  TComboBoxInfo = packed record
    cbSize: DWORD;
    rcItem: TRect;
    rcButton: TRect;
    stateButton: DWORD;
    hwndCombo: HWND;
    hwndItem: HWND;
    hwndList: HWND;
  end;

function GetComboBoxInfo(hwndCombo: HWND; var Info: TComboBoxInfo): BOOL;
  stdcall; external 'user32.dll' name 'GetComboBoxInfo';

const
  LB_GETCURSEL = $0188;
  LB_SETCURSEL = $0186;
  LB_GETCOUNT  = $018B;
  CB_SETCURSEL = $014E;
  CB_GETDROPPEDSTATE = $0157;

function ComboDroppedDown(Combo: HWND): Boolean;
begin
  Result := SendMessage(Combo, CB_GETDROPPEDSTATE, 0, 0) <> 0;
end;

procedure TMainForm.cbTaskKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  // Arrow + Enter handling lives in the Win32 edit subclass (EditSubProc).
  // LCL OnKeyDown doesn't reliably fire for arrow keys inside the combo's
  // edit when the dropdown is open, so we hook at the Win32 level.
end;

procedure TMainForm.DeferredFocusStart(Data: PtrInt);
begin
  if btnStartStop.CanFocus then
    btnStartStop.SetFocus;
end;

procedure TMainForm.DeferredStartFromEnter(Data: PtrInt);
var
  cbi: TComboBoxInfo;
  idx: Integer;
begin
  // Enter in open dropdown: commit highlighted listbox item to combo and
  // close — don't start the timer (the user is just picking).
  if ComboDroppedDown(cbTask.Handle) then
  begin
    cbi.cbSize := SizeOf(cbi);
    if GetComboBoxInfo(cbTask.Handle, cbi) and (cbi.hwndList <> 0) then
    begin
      idx := SendMessage(cbi.hwndList, LB_GETCURSEL, 0, 0);
      if idx >= 0 then
      begin
        SendMessage(cbTask.Handle, CB_SETCURSEL, idx, 0);
        cbTask.DroppedDown := False;
      end;
    end;
    Exit;
  end;
  // Closed dropdown: Enter starts the task with whatever text is there.
  btnStartStopClick(nil);
end;

function TokensMatch(const LItem: string; const Tokens: array of string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Tokens) do
    if (Tokens[i] <> '') and (Pos(Tokens[i], LItem) = 0) then
      Exit(False);
  Result := True;
end;

procedure SplitTokens(const S: string; out Tokens: TStringArray);
var
  i, n, start: Integer;
begin
  Tokens := nil;
  n := 0;
  i := 1;
  while i <= Length(S) do
  begin
    while (i <= Length(S)) and (S[i] = ' ') do Inc(i);
    if i > Length(S) then Break;
    start := i;
    while (i <= Length(S)) and (S[i] <> ' ') do Inc(i);
    SetLength(Tokens, n + 1);
    Tokens[n] := Copy(S, start, i - start);
    Inc(n);
  end;
end;

procedure TMainForm.RestoreFullList;
var
  Filter: string;
  OldStart, OldLen: Integer;
begin
  if not FItemsAreFiltered then Exit;
  FFiltering := True;
  try
    Filter := cbTask.Text;
    OldStart := cbTask.SelStart;
    OldLen := cbTask.SelLength;
    cbTask.Items.BeginUpdate;
    try
      cbTask.Items.Clear;
      cbTask.Items.AddStrings(FAllTasks);
    finally
      cbTask.Items.EndUpdate;
    end;
    cbTask.Text := Filter;
    cbTask.SelStart := OldStart;
    cbTask.SelLength := OldLen;
    FItemsAreFiltered := False;
  finally
    FFiltering := False;
  end;
end;

procedure TMainForm.ApplyComboFilter;
var
  Filter, LFilter, S: string;
  i, OldStart, OldLen: Integer;
  Tokens: TStringArray;
begin
  FFiltering := True;
  try
    Filter := cbTask.Text;
    LFilter := UTF8LowerCase(Filter);
    SplitTokens(LFilter, Tokens);
    OldStart := cbTask.SelStart;
    OldLen := cbTask.SelLength;
    cbTask.Items.BeginUpdate;
    try
      cbTask.Items.Clear;
      for i := 0 to FAllTasks.Count - 1 do
      begin
        S := FAllTasks[i];
        if TokensMatch(UTF8LowerCase(S), Tokens) then
          cbTask.Items.Add(S);
      end;
    finally
      cbTask.Items.EndUpdate;
    end;
    FItemsAreFiltered := True;
    cbTask.Text := Filter;
    cbTask.SelStart := OldStart;
    cbTask.SelLength := OldLen;
    if cbTask.Focused and (cbTask.Items.Count > 0) and not ComboDroppedDown(cbTask.Handle) then
    begin
      FProgrammaticDrop := True;
      cbTask.DroppedDown := True;
    end;
  finally
    FFiltering := False;
  end;
end;

procedure TMainForm.ApplyHideFromTaskBar;
const
  WS_EX_TOOLWINDOW_FLAG = $00000080;
var
  H: HWND;
  Ex: PtrInt;
begin
  // With MainFormOnTaskBar=False the taskbar entry belongs to Application's
  // hidden window, so toggle its tool-window flag, not the main form's.
  H := Application.Handle;
  if H = 0 then Exit;
  Ex := GetWindowLongPtr(H, GWL_EXSTYLE);
  if miHideFromTaskBar.Checked then
    Ex := Ex or WS_EX_TOOLWINDOW_FLAG
  else
    Ex := Ex and not WS_EX_TOOLWINDOW_FLAG;
  SetWindowLongPtr(H, GWL_EXSTYLE, Ex);
  ShowWindow(H, SW_HIDE);
  ShowWindow(H, SW_SHOW);
end;

procedure TMainForm.ApplyTopMost;
begin
  if miTopMost.Checked then
  begin
    if FormStyle <> fsStayOnTop then FormStyle := fsStayOnTop;
    // Two-step set is the documented reliable way: clear, then set.
    SetWindowPos(Self.Handle, HWND_NOTOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
    SetWindowPos(Self.Handle, HWND_TOPMOST,   0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end
  else
  begin
    if FormStyle <> fsNormal then FormStyle := fsNormal;
    SetWindowPos(Self.Handle, HWND_NOTOPMOST, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  end;
end;

{ -------- menu -------- }

procedure TMainForm.miExitClick(Sender: TObject);
begin
  Close;
end;

procedure TMainForm.miStatsClick(Sender: TObject);
begin
  if StatsForm = nil then
    StatsForm := TStatsForm.Create(Application);
  StatsForm.ShowFor(FDataDir);
end;

procedure TMainForm.miEditClick(Sender: TObject);
begin
  if EditForm = nil then
    EditForm := TEditForm.Create(Application);
  EditForm.ShowFor(FDataDir);
end;

procedure TMainForm.miHideFromTaskBarClick(Sender: TObject);
begin
  ApplyHideFromTaskBar;
  SaveConfig;
end;

procedure TMainForm.TrayIcon1DblClick(Sender: TObject);
begin
  Show;
  BringToFront;
end;

procedure TMainForm.miTopMostClick(Sender: TObject);
begin
  ApplyTopMost;
  SaveConfig;
end;

procedure TMainForm.miOpacityClick(Sender: TObject);
begin
  if Sender is TMenuItem then
  begin
    FOpacity := TMenuItem(Sender).Tag;
    TMenuItem(Sender).Checked := True;
    ApplyOpacity(FOpacity);
    SaveConfig;
  end;
end;

procedure TMainForm.ApplyOpacity(APercent: Integer);
const
  WS_EX_LAYERED_FLAG = $00080000;
  LWA_ALPHA = $00000002;
var
  H: HWND;
  Ex: PtrInt;
begin
  if not HandleAllocated then Exit;
  H := Self.Handle;
  Ex := GetWindowLongPtr(H, GWL_EXSTYLE);
  if APercent >= 100 then
  begin
    // Fully opaque — remove layered style entirely
    if (Ex and WS_EX_LAYERED_FLAG) <> 0 then
      SetWindowLongPtr(H, GWL_EXSTYLE, Ex and not WS_EX_LAYERED_FLAG);
    Exit;
  end;
  if (Ex and WS_EX_LAYERED_FLAG) = 0 then
    SetWindowLongPtr(H, GWL_EXSTYLE, Ex or WS_EX_LAYERED_FLAG);
  SetLayeredWindowAttributes(H, 0, Round(255 * APercent / 100), LWA_ALPHA);
end;

{ -------- config -------- }

procedure TMainForm.LoadConfig;
var
  Doc: TXMLDocument;
  Root: TDOMElement;
  S: string;
  V: Integer;
begin
  if not FileExists(FConfigFile) then Exit;
  Doc := nil;
  try
    try
      ReadXMLFile(Doc, FConfigFile);
      Root := Doc.DocumentElement;
      S := Root.GetAttribute('left');   if TryStrToInt(S, V) then Left := V;
      S := Root.GetAttribute('top');    if TryStrToInt(S, V) then Top := V;
      S := Root.GetAttribute('width');  if TryStrToInt(S, V) and (V >= 304) then Width := V;
      S := Root.GetAttribute('height'); if TryStrToInt(S, V) and (V >= 32) then Height := V;
      S := Root.GetAttribute('topMost');
      if S = '0' then
        miTopMost.Checked := False;
      S := Root.GetAttribute('hideFromTaskBar');
      if S = '1' then
        miHideFromTaskBar.Checked := True;
      S := Root.GetAttribute('opacity');
      if TryStrToInt(S, V) and (V >= 10) and (V <= 100) then
        FOpacity := V;
    except
    end;
  finally
    Doc.Free;
  end;
end;

procedure TMainForm.SaveConfig;
var
  Doc: TXMLDocument;
  Root: TDOMElement;
begin
  Doc := TXMLDocument.Create;
  try
    Root := Doc.CreateElement('config');
    Doc.AppendChild(Root);
    Root.SetAttribute('left',   IntToStr(Left));
    Root.SetAttribute('top',    IntToStr(Top));
    Root.SetAttribute('width',  IntToStr(Width));
    Root.SetAttribute('height', IntToStr(Height));
    if miTopMost.Checked then Root.SetAttribute('topMost', '1')
                         else Root.SetAttribute('topMost', '0');
    if miHideFromTaskBar.Checked then Root.SetAttribute('hideFromTaskBar', '1')
                                 else Root.SetAttribute('hideFromTaskBar', '0');
    Root.SetAttribute('opacity', IntToStr(FOpacity));
    WriteXMLFile(Doc, FConfigFile);
  finally
    Doc.Free;
  end;
end;

{ -------- storage -------- }

function TMainForm.TodayLogFile: string;
begin
  Result := FDataDir + PathDelim + FormatDateTime('yyyy-mm-dd', Now) + '.xml';
end;

procedure TMainForm.LoadTaskHistory;
var
  Doc: TXMLDocument;
  Node: TDOMNode;
  S, LU: string;
  Pairs: TStringList;
  i: Integer;
begin
  FAllTasks.Clear;
  cbTask.Items.Clear;
  if not FileExists(FTasksFile) then Exit;
  Pairs := TStringList.Create;
  Doc := nil;
  try
    try
      ReadXMLFile(Doc, FTasksFile);
      Node := Doc.DocumentElement.FirstChild;
      while Node <> nil do
      begin
        if (Node.NodeName = 'task') and (Node.Attributes <> nil)
           and (Node.Attributes.GetNamedItem('name') <> nil) then
        begin
          S := Node.Attributes.GetNamedItem('name').NodeValue;
          LU := '';
          if Node.Attributes.GetNamedItem('lastUsed') <> nil then
            LU := Node.Attributes.GetNamedItem('lastUsed').NodeValue;
          // Sort key first so TStringList.Sort orders by lastUsed desc.
          // Pad/normalize: use the ISO string as-is (already lexicographic).
          if S <> '' then Pairs.Add(LU + #9 + S);
        end;
        Node := Node.NextSibling;
      end;
    except
    end;
  finally
    Doc.Free;
  end;
  Pairs.Sort;
  // Sort is ascending → walk from end for MRU first
  for i := Pairs.Count - 1 downto 0 do
  begin
    S := Pairs[i];
    FAllTasks.Add(Copy(S, Pos(#9, S) + 1, MaxInt));
  end;
  Pairs.Free;
  cbTask.Items.AddStrings(FAllTasks);
end;

procedure TMainForm.SaveTaskToHistory(const ATask: string);
var
  Doc: TXMLDocument;
  Root, El: TDOMElement;
  Node: TDOMNode;
  Found: Boolean;
  Idx: Integer;
  NowStr: string;
begin
  // MRU: move/insert at top of in-memory list.
  Idx := FAllTasks.IndexOf(ATask);
  if Idx >= 0 then
    FAllTasks.Move(Idx, 0)
  else
    FAllTasks.Insert(0, ATask);

  // Reflect in dropdown if the full list is currently shown.
  if not FItemsAreFiltered then
  begin
    FFiltering := True;
    try
      cbTask.Items.BeginUpdate;
      try
        cbTask.Items.Clear;
        cbTask.Items.AddStrings(FAllTasks);
      finally
        cbTask.Items.EndUpdate;
      end;
    finally
      FFiltering := False;
    end;
  end;

  NowStr := FormatDateTime(IsoFmt, Now);
  Doc := nil;
  Found := False;
  try
    if FileExists(FTasksFile) then
    begin
      ReadXMLFile(Doc, FTasksFile);
      Root := Doc.DocumentElement;
    end
    else
    begin
      Doc := TXMLDocument.Create;
      Root := Doc.CreateElement('tasks');
      Doc.AppendChild(Root);
    end;

    Node := Root.FirstChild;
    while Node <> nil do
    begin
      if (Node.NodeName = 'task') and (Node.Attributes <> nil)
         and (Node.Attributes.GetNamedItem('name') <> nil)
         and (Node.Attributes.GetNamedItem('name').NodeValue = ATask) then
      begin
        TDOMElement(Node).SetAttribute('lastUsed', NowStr);
        Found := True;
        Break;
      end;
      Node := Node.NextSibling;
    end;

    if not Found then
    begin
      El := Doc.CreateElement('task');
      El.SetAttribute('name', ATask);
      El.SetAttribute('lastUsed', NowStr);
      Root.AppendChild(El);
    end;
    WriteXMLFile(Doc, FTasksFile);
  finally
    Doc.Free;
  end;
end;

procedure TMainForm.AppendEntry(const ATask: string; AStart, AEnd: TDateTime);
var
  Doc: TXMLDocument;
  Root, El: TDOMElement;
  LogFile: string;
  DurMS: Int64;
begin
  LogFile := TodayLogFile;
  Doc := nil;
  try
    if FileExists(LogFile) then
    begin
      ReadXMLFile(Doc, LogFile);
      Root := Doc.DocumentElement;
    end
    else
    begin
      Doc := TXMLDocument.Create;
      Root := Doc.CreateElement('day');
      Root.SetAttribute('date', FormatDateTime('yyyy-mm-dd', AStart));
      Doc.AppendChild(Root);
    end;

    DurMS := Round((AEnd - AStart) * 86400000);
    El := Doc.CreateElement('entry');
    El.SetAttribute('task', ATask);
    El.SetAttribute('start', FormatDateTime(IsoFmt, AStart));
    El.SetAttribute('end',   FormatDateTime(IsoFmt, AEnd));
    El.SetAttribute('duration', FormatDateTime(TimeFmt, AEnd - AStart));
    El.SetAttribute('durationMs', IntToStr(DurMS));
    Root.AppendChild(El);
    WriteXMLFile(Doc, LogFile);
  finally
    Doc.Free;
  end;
end;

end.
