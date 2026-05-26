unit umain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls, Menus,
  Buttons, Graphics, LCLType, LMessages, Dialogs, Windows, Types, uaudio,
  uaudiolist;

type
  TMainForm = class(TForm)
    btnSettings: TSpeedButton;
    btnStartStop: TButton;
    btnMic: TSpeedButton;
    btnMicDrop: TSpeedButton;
    btnSys: TSpeedButton;
    btnRec: TSpeedButton;
    btnVAD: TSpeedButton;
    btnAudioList: TSpeedButton;
    cbTask: TComboBox;
    lblTodayTotal: TLabel;
    lblAudio: TLabel;
    miAudio: TMenuItem;
    miAudioDir: TMenuItem;
    miMic: TMenuItem;
    miAudioQ: TMenuItem;
    miAudioQLow: TMenuItem;
    miAudioQMid: TMenuItem;
    miAudioQHigh: TMenuItem;
    miVadSens: TMenuItem;
    miVadHigh: TMenuItem;
    miVadMid: TMenuItem;
    miVadLow: TMenuItem;
    pbSlider: TPaintBox;
    miBuildInfo: TMenuItem;
    miSepBuild: TMenuItem;
    miStats: TMenuItem;
    miEdit: TMenuItem;
    miEditTasks: TMenuItem;
    miLazyCureDir: TMenuItem;
    miHideFromTaskBar: TMenuItem;
    miTopMost: TMenuItem;
    miOpacity: TMenuItem;
    miSep1: TMenuItem;
    miAbout: TMenuItem;
    miSep2: TMenuItem;
    miExit: TMenuItem;
    PopupMenu1: TPopupMenu;
    Timer1: TTimer;
    DeselTimer: TTimer;
    TrayIcon1: TTrayIcon;
    procedure btnSettingsClick(Sender: TObject);
    procedure btnStartStopClick(Sender: TObject);
    procedure pbSliderMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbSliderMouseLeave(Sender: TObject);
    procedure pbSliderMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
    procedure pbSliderMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure pbSliderPaint(Sender: TObject);
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
    procedure miEditTasksClick(Sender: TObject);
    procedure miAboutClick(Sender: TObject);
    procedure miExitClick(Sender: TObject);
    procedure miHideFromTaskBarClick(Sender: TObject);
    procedure miLazyCureDirClick(Sender: TObject);
    procedure miOpacityClick(Sender: TObject);
    procedure miAudioDirClick(Sender: TObject);
    procedure miAudioQClick(Sender: TObject);
    procedure miAudioClick(Sender: TObject);
    procedure MicMenuClick(Sender: TObject);
    procedure btnMicClick(Sender: TObject);
    procedure btnSysClick(Sender: TObject);
    procedure btnRecClick(Sender: TObject);
    procedure btnVADClick(Sender: TObject);
    procedure miVadSensClick(Sender: TObject);
    procedure btnAudioListClick(Sender: TObject);
    procedure AudioListHidden(Sender: TObject);
    procedure btnMicDropClick(Sender: TObject);
    procedure MicDropMenuClick(Sender: TObject);
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
    FSliderLocked: Boolean;
    FLockedMs: Int64;
    FSliderDragging: Boolean;
    FGrabX1, FGrabX2: Integer; // hitbox for drag (flag + "now" label)
    FLazyCureDir: string;
    FOpacityLbl: TLabel;
    FOpacitySupported: Boolean;
    FAudioDir: string;
    FAudioQuality: TAudioQuality;
    FAudioRecorder: TAudioRecorder;
    FAudioFilesForSegment: TStringList;
    FLastAudioFileSize: Int64;
    FAudioUnchangedTicks: Integer;
    FAudioPaused: Boolean;
    FAudioPauseStart: QWord;     // GetTickCount64 when current pause began
    FAudioPausedTotalMs: QWord;  // accumulated paused-time for this recording
    FRecStartTickMs: QWord;      // precise wall-clock at recording start
    FAudioListForm: TAudioListForm;
    FMicDevice: string;
    FMicDropMenu: TPopupMenu;
    procedure RefreshMicDropdownVisibility;
    procedure AnchorAudioListForm;
    procedure StartRecording;
    procedure StopRecording;
    procedure UpdateAudioStatus;
    function ResolvedAudioDir: string;
    procedure OpacityTrackChange(Sender: TObject);
    function CheckOpacitySupported: Boolean;
    function CurrentElapsedMs: Int64;
    function DisplayedMs: Int64;
    procedure UpdateSliderFromX(X: Integer);
    function ResolvedLazyCureDir: string;
    procedure StartTask;
    procedure StopTask;
    procedure WriteCurrentMarker;
    procedure UpdateCurrentMarker;
    procedure DeleteCurrentMarker;
    procedure RecoverOrphanedTask;
    procedure RefreshTodayTotal;
    function ComputeTodayTotalMs(const Task: string): Int64;
    procedure LoadTaskHistory;
    procedure SaveTaskToHistory(const ATask: string);
    procedure AppendEntry(const ATask: string; AStart, AEnd: TDateTime;
      AudioFiles: TStrings = nil);
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
  LazFileUtils, LCLIntf, DOM, XMLRead, XMLWrite, LazUTF8, FileCtrl,
  ComObj, ActiveX, ustats, uedit, utaskedit;

const
  CLSID_TaskbarList: TGUID = '{56FDF344-FD6D-11d0-958A-006097C9A090}';
  SID_ITaskbarList  = '{56FDF342-FD6D-11d0-958A-006097C9A090}';

type
  ITaskbarList = interface(IUnknown)
    [SID_ITaskbarList]
    function HrInit: HRESULT; stdcall;
    function AddTab(hwnd: HWND): HRESULT; stdcall;
    function DeleteTab(hwnd: HWND): HRESULT; stdcall;
    function ActivateTab(hwnd: HWND): HRESULT; stdcall;
    function SetActiveAlt(hwnd: HWND): HRESULT; stdcall;
  end;

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
function FormatHMinCompact(MsTotal: Int64): string; forward;

procedure DbgLog(const S: string);
var
  H: THandle;
  Line: AnsiString;
const
  P = 'd:\Develop\EXE\TimeRec\bin\trdbg.log';
begin
  if FileExists(P) then
    H := FileOpen(P, fmOpenWrite or fmShareDenyNone)
  else
    H := FileCreate(P);
  if H = THandle(-1) then Exit;
  FileSeek(H, 0, 2); // end
  Line := FormatDateTime('hh:nn:ss.zzz', Now) + ' ' + S + #13#10;
  FileWrite(H, Line[1], Length(Line));
  FileClose(H);
end;

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
  // v2 model: always recording. The segment starts when the form opens
  // and a "Done" click fixates it + starts the next segment.
  FRunning := True;
  FTaskStart := Now;
  FCurrentTask := '';
  FOpacity := 100;
  FOpacitySupported := CheckOpacitySupported;
  FAudioDir := '';
  cbTask.DropDownCount := 20;  // default — overridden by config later
  FAudioQuality := aqMid;
  FAudioRecorder := TAudioRecorder.Create(AppDir);
  FAudioFilesForSegment := TStringList.Create;
  FMicDevice := '';
  FHighlightedIdx := -1;
  FSliderLocked := False;
  FLockedMs := 0;
  FSliderDragging := False;
  // Build-time stamp injected by FPC. %DATE% → yyyy/mm/dd, %TIME% → hh:mm:ss
  miBuildInfo.Caption := 'Сборка: ' +
    Copy({$I %DATE%}, 9, 2) + '.' + Copy({$I %DATE%}, 6, 2) + '.' +
    Copy({$I %DATE%}, 1, 4) + ' ' + Copy({$I %TIME%}, 1, 5);
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
  // Allow the Start/Stop button to render Caption on two lines
  if btnStartStop.HandleAllocated then
    SetWindowLong(btnStartStop.Handle, GWL_STYLE,
      GetWindowLong(btnStartStop.Handle, GWL_STYLE) or $00002000); // BS_MULTILINE
  // LFM placeholders are 'M'/'S'; assign real emoji glyphs at runtime
  // because LFM #NNNN only supports the BMP and 🎤/🔊 live above U+FFFF.
  btnMic.Caption := #$F0#$9F#$8E#$A4;  // 🎤
  btnSys.Caption := #$F0#$9F#$94#$8A;  // 🔊
  RefreshMicDropdownVisibility;
  FormResize(nil);

  // Apply persisted opacity. The control lives in a slider dialog now,
  // so no checked-state to sync.
  if FOpacitySupported then
    ApplyOpacity(FOpacity)
  else
  begin
    miOpacity.Enabled := False;
    miOpacity.Caption := 'Прозрачность (недоступно)';
  end;
end;

procedure TMainForm.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  if FAudioRecorder <> nil then
  begin
    if FAudioRecorder.IsRecording then FAudioRecorder.Stop;
  end;
  if FRunning then
    StopTask;
  SaveConfig;
  FAllTasks.Free;
  FreeAndNil(FAudioRecorder);
  FreeAndNil(FAudioFilesForSegment);
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
  FontBase = 11;
var
  BaseH, BaseW, WantH, NewFont: Integer;
  S: Double;
begin
  if not HandleAllocated then Exit;
  if btnMic.Visible then BaseH := 80 else BaseH := 54;
  BaseW := 340;
  WantH := Round(Width * BaseH / BaseW);
  if Height <> WantH then Height := WantH;
  S := Width / BaseW;
  NewFont := -Round(FontBase * S);
  Font.Height := NewFont;
  btnSettings.SetBounds  (Round(4 * S),   Round(2 * S),  Round(22 * S),  Round(28 * S));
  lblTodayTotal.SetBounds(Round(30 * S),  Round(10 * S), Round(50 * S),  Round(13 * S));
  lblTodayTotal.Font.Height := NewFont;
  cbTask.SetBounds       (Round(84 * S),  Round(5 * S),  Round(156 * S), Round(21 * S));
  btnStartStop.SetBounds (Round(244 * S), Round(2 * S),  Round(92 * S),  Round(28 * S));
  pbSlider.SetBounds     (Round(4 * S),   Round(32 * S), Round(332 * S), Round(22 * S));
  btnMic.SetBounds       (Round(4 * S),   Round(56 * S), Round(28 * S),  Round(22 * S));
  btnMicDrop.SetBounds   (Round(32 * S),  Round(56 * S), Round(12 * S),  Round(22 * S));
  btnSys.SetBounds       (Round(48 * S),  Round(56 * S), Round(28 * S),  Round(22 * S));
  btnRec.SetBounds       (Round(80 * S),  Round(56 * S), Round(60 * S),  Round(22 * S));
  btnVAD.SetBounds       (Round(144 * S), Round(56 * S), Round(28 * S),  Round(22 * S));
  lblAudio.SetBounds     (Round(176 * S), Round(60 * S), Round(160 * S), Round(14 * S));
  lblAudio.Font.Height := NewFont;
  Application.QueueAsyncCall(@DeselectCombo, 0);
  AnchorAudioListForm;
end;

procedure TMainForm.Timer1Timer(Sender: TObject);
begin
  btnStartStop.Caption := 'Сделано' + LineEnding +
    FormatDateTime(TimeFmt, CurrentElapsedMs / 86400000);
  pbSlider.Invalidate;
  RefreshTodayTotal;
  UpdateAudioStatus;
  AnchorAudioListForm;
  if (Now - FLastAlive) * 86400 > 10 then
    UpdateCurrentMarker;
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
  BaseW = 340;
  BaseH = 80;
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
var
  T: string;
  Dur: Int64;
  EndDT: TDateTime;
begin
  T := Trim(cbTask.Text);
  if T = '' then T := 'Не учтенно';
  Dur := DisplayedMs;
  if Dur < 1000 then
  begin
    // Less than a second — nothing meaningful to record, just refresh.
    FTaskStart := Now;
    FSliderLocked := False;
    FLockedMs := 0;
    Exit;
  end;
  EndDT := FTaskStart + Dur / 86400000;
  // Stop any active recording so the file is finalized before attach.
  if FAudioRecorder.IsRecording then StopRecording;
  AppendEntry(T, FTaskStart, EndDT, FAudioFilesForSegment);
  FAudioFilesForSegment.Clear;
  // The new segment starts at the cut point.
  FTaskStart := EndDT;
  FSliderLocked := False;
  FLockedMs := 0;
  btnRec.Down := False;
  SaveTaskToHistory(T);
  // Clear the task name so the user has to pick or type the next one.
  FCurrentTask := '';
  FFiltering := True;
  try
    cbTask.Text := '';
    cbTask.ItemIndex := -1;
  finally
    FFiltering := False;
  end;
  WriteCurrentMarker;
  RefreshTodayTotal;
  Timer1Timer(nil);
end;

function TMainForm.CurrentElapsedMs: Int64;
begin
  Result := Round((Now - FTaskStart) * 86400000);
  if Result < 0 then Result := 0;
end;

function TMainForm.DisplayedMs: Int64;
begin
  if FSliderLocked then
  begin
    Result := FLockedMs;
    if Result > CurrentElapsedMs then Result := CurrentElapsedMs;
    if Result < 0 then Result := 0;
  end
  else
    Result := CurrentElapsedMs;
end;

procedure TMainForm.UpdateSliderFromX(X: Integer);
const
  Margin = 4;
  SnapZone = 4;  // px from right edge that snap back to "unlocked / track live"
var
  Elapsed: Int64;
  TrackL, TrackR: Integer;
  Frac: Double;
begin
  TrackL := Margin;
  TrackR := pbSlider.Width - Margin;
  if X < TrackL then X := TrackL;
  if X > TrackR then X := TrackR;
  if TrackR <= TrackL then Exit;
  // Dragged all the way to the right edge: unlock so the marker resumes
  // tracking elapsed time automatically.
  if X >= TrackR - SnapZone then
  begin
    FSliderLocked := False;
    pbSlider.Invalidate;
    Exit;
  end;
  Frac := (X - TrackL) / (TrackR - TrackL);
  Elapsed := CurrentElapsedMs;
  FLockedMs := Round(Elapsed * Frac);
  FSliderLocked := True;
  pbSlider.Invalidate;
end;

procedure TMainForm.pbSliderMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
const
  WM_NCLBUTTONDOWN_ = $00A1;
begin
  if Button <> mbLeft then Exit;
  if (X >= FGrabX1) and (X <= FGrabX2) then
  begin
    // Inside the flag / "now-at-flag" hitbox: drag the slider.
    FSliderDragging := True;
    UpdateSliderFromX(X);
  end
  else
  begin
    // Anywhere else on the slider area: drag the window itself.
    ReleaseCapture;
    SendMessage(Self.Handle, WM_NCLBUTTONDOWN_, HTCAPTION, 0);
  end;
end;

procedure TMainForm.pbSliderMouseMove(Sender: TObject; Shift: TShiftState;
  X, Y: Integer);
begin
  if FSliderDragging then UpdateSliderFromX(X);
end;

procedure TMainForm.pbSliderMouseUp(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
begin
  if Button = mbLeft then FSliderDragging := False;
end;

procedure TMainForm.pbSliderMouseLeave(Sender: TObject);
var
  P: TPoint;
begin
  // Cancel an active drag if the cursor has left the form entirely.
  // (Staying inside the form but moving off the paintbox doesn't cancel
  // — the user might be tracing along the top edge.)
  if not FSliderDragging then Exit;
  GetCursorPos(P);
  if (P.X < Self.Left) or (P.X >= Self.Left + Self.Width) or
     (P.Y < Self.Top) or (P.Y >= Self.Top + Self.Height) then
    FSliderDragging := False;
end;

procedure TMainForm.pbSliderPaint(Sender: TObject);
const
  Margin = 4;
var
  C: TCanvas;
  W, H, ThumbX, ArrowY: Integer;
  TrackL, TrackR: Integer;
  Elapsed, Disp: Int64;
  Frac: Double;
  StartStr, NowStr, DurStr: string;
  StartW, NowW, DurW: Integer;
  StartX, NowX, DurX, TextY: Integer;
begin
  C := pbSlider.Canvas;
  W := pbSlider.Width;
  H := pbSlider.Height;
  C.Brush.Color := Color;
  C.FillRect(0, 0, W, H);

  TrackL := Margin;
  TrackR := W - Margin;
  ArrowY := H - 4;
  // Smaller slider font so text + arrow + flag don't crowd each other.
  C.Font.Height := -10;
  Elapsed := CurrentElapsedMs;
  Disp := DisplayedMs;
  if Elapsed = 0 then Frac := 1.0 else Frac := Disp / Elapsed;
  if Frac < 0 then Frac := 0;
  if Frac > 1 then Frac := 1;
  ThumbX := TrackL + Round((TrackR - TrackL) * Frac);

  // Arrow line
  C.Pen.Color := clGray;
  C.Pen.Width := 1;
  C.MoveTo(TrackL, ArrowY);
  C.LineTo(ThumbX, ArrowY);
  // Left arrowhead (points left ◀)
  C.MoveTo(TrackL, ArrowY);     C.LineTo(TrackL + 4, ArrowY - 3);
  C.MoveTo(TrackL, ArrowY);     C.LineTo(TrackL + 4, ArrowY + 3);
  // Right arrowhead at thumb (▶)
  C.MoveTo(ThumbX, ArrowY);     C.LineTo(ThumbX - 4, ArrowY - 3);
  C.MoveTo(ThumbX, ArrowY);     C.LineTo(ThumbX - 4, ArrowY + 3);

  // Flag: pole + triangle to the LEFT of the pole so it never clips
  // on the right edge of the form.
  C.Pen.Color := clBlack;
  C.Pen.Width := 1;
  C.MoveTo(ThumbX, ArrowY);
  C.LineTo(ThumbX, ArrowY - 8);
  if FSliderLocked then C.Brush.Color := clRed
  else                  C.Brush.Color := clGreen;
  C.Pen.Color := clMaroon;
  C.Polygon([Point(ThumbX,     ArrowY - 8),
             Point(ThumbX - 7, ArrowY - 6),
             Point(ThumbX,     ArrowY - 3)]);
  C.Brush.Color := Color;

  // ----- Top row of labels -----
  TextY := 0;
  C.Font.Color := clWindowText;
  StartStr := FormatDateTime('hh:nn', FTaskStart);
  NowStr   := FormatDateTime('hh:nn', FTaskStart + Disp / 86400000);
  DurStr   := FormatHMinCompact(Disp);
  StartW := C.TextWidth(StartStr);
  NowW   := C.TextWidth(NowStr);
  DurW   := C.TextWidth(DurStr);
  // Start time placed slightly to the right of the left arrowhead so
  // the arrowhead stays visible.
  StartX := TrackL + 8;
  // "Now-at-flag" time placed slightly to the LEFT of the flag pole so
  // the flag stays visible, and clamped within the canvas.
  NowX := ThumbX - 10 - NowW;
  if NowX + NowW > W - 2 then NowX := W - 2 - NowW;
  if NowX < StartX + StartW + 6 then NowX := StartX + StartW + 6;
  // Duration label centered between the two time labels, skipped if it
  // would overlap them.
  DurX := (StartX + StartW + NowX) div 2 - DurW div 2;
  C.TextOut(StartX, TextY, StartStr);
  if (DurX > StartX + StartW + 4) and (DurX + DurW < NowX - 4) then
    C.TextOut(DurX, TextY, DurStr);
  C.TextOut(NowX, TextY, NowStr);

  // Remember the hitbox the mouse handler will accept for dragging:
  // from the start of the "now-at-flag" label through past the flag.
  FGrabX1 := NowX - 2;
  FGrabX2 := ThumbX + 4;
end;

procedure TMainForm.btnSettingsClick(Sender: TObject);
var
  P: TPoint;
begin
  P.X := 0;
  P.Y := btnSettings.Height;
  P := btnSettings.ClientToScreen(P);
  PopupMenu1.PopUp(P.X, P.Y);
end;

function FormatHMinCompact(MsTotal: Int64): string;
var
  TotalMin, H, M: Int64;
begin
  TotalMin := MsTotal div 60000;
  if TotalMin = 0 then Exit('0мин');
  H := TotalMin div 60;
  M := TotalMin mod 60;
  if H = 0 then      Result := IntToStr(M) + 'мин'
  else if M = 0 then Result := IntToStr(H) + 'ч'
  else               Result := IntToStr(H) + 'ч' + IntToStr(M);
end;

function TMainForm.ComputeTodayTotalMs(const Task: string): Int64;
var
  Doc: TXMLDocument;
  Node: TDOMNode;
  EntryTask, DurStr: string;
  F: string;
begin
  Result := 0;
  if Task = '' then Exit;
  F := FDataDir + PathDelim + FormatDateTime('yyyy-mm-dd', Now) + '.xml';
  if FileExists(F) then
  begin
    Doc := nil;
    try
      try
        ReadXMLFile(Doc, F);
        Node := Doc.DocumentElement.FirstChild;
        while Node <> nil do
        begin
          if (Node.NodeName = 'entry') and (Node.Attributes <> nil)
             and (Node.Attributes.GetNamedItem('task') <> nil)
             and (Node.Attributes.GetNamedItem('durationMs') <> nil) then
          begin
            EntryTask := Node.Attributes.GetNamedItem('task').NodeValue;
            if EntryTask = Task then
            begin
              DurStr := Node.Attributes.GetNamedItem('durationMs').NodeValue;
              Inc(Result, StrToInt64Def(DurStr, 0));
            end;
          end;
          Node := Node.NextSibling;
        end;
      except
      end;
    finally
      Doc.Free;
    end;
  end;
  // Add the ongoing session if it's for this task
  if FRunning and (FCurrentTask = Task) then
    Inc(Result, Round((Now - FTaskStart) * 86400000));
end;

procedure TMainForm.RefreshTodayTotal;
var
  T: string;
begin
  T := Trim(cbTask.Text);
  if T = '' then
    lblTodayTotal.Caption := ''
  else
    lblTodayTotal.Caption := FormatHMinCompact(ComputeTodayTotalMs(T));
end;

procedure TMainForm.StartTask; begin end;
procedure TMainForm.StopTask;
begin
  // On close: fixate the in-progress segment if there's a task name.
  if Trim(cbTask.Text) <> '' then
  begin
    FCurrentTask := Trim(cbTask.Text);
    AppendEntry(FCurrentTask, FTaskStart, FTaskStart + DisplayedMs / 86400000);
  end;
  DeleteCurrentMarker;
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
  // Trigger a delayed deselect (timer runs after Windows finishes its
  // CBN_SELCHANGE focus handling).
  DeselTimer.Enabled := False;
  DeselTimer.Enabled := True;
  RefreshTodayTotal;
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
  // Lazy-subclass the inner Edit and the dropdown listbox on first
  // dropdown — both exist by now.
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
// Compute the filtered list and apply it as a diff against the
// combobox's current Items, so only the rows that actually change
// get invalidated. The previous Clear+AddStrings approach made the
// open dropdown flash on every keystroke.
var
  Filter, LFilter, S: string;
  i, j, OldStart, OldLen: Integer;
  Tokens: TStringArray;
  NewList: TStringList;
begin
  FFiltering := True;
  NewList := TStringList.Create;
  try
    Filter := cbTask.Text;
    LFilter := UTF8LowerCase(Filter);
    SplitTokens(LFilter, Tokens);
    OldStart := cbTask.SelStart;
    OldLen := cbTask.SelLength;
    for i := 0 to FAllTasks.Count - 1 do
    begin
      S := FAllTasks[i];
      if TokensMatch(UTF8LowerCase(S), Tokens) then
        NewList.Add(S);
    end;
    cbTask.Items.BeginUpdate;
    try
      i := 0;
      while i < NewList.Count do
      begin
        if i >= cbTask.Items.Count then
          cbTask.Items.Add(NewList[i])
        else if cbTask.Items[i] = NewList[i] then
          // keep
        else
        begin
          // Look ahead: does the current item appear later in the new
          // list? If so insert before it. Otherwise drop it.
          j := NewList.IndexOf(cbTask.Items[i]);
          if (j > i) then
            cbTask.Items.Insert(i, NewList[i])
          else
            cbTask.Items.Delete(i);
          Continue;
        end;
        Inc(i);
      end;
      while cbTask.Items.Count > NewList.Count do
        cbTask.Items.Delete(cbTask.Items.Count - 1);
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
    // Windows' "hide pointer while typing" feature decrements the
    // global cursor counter on each keystroke. Mutating the dropdown's
    // Items list while typing seems to keep the counter negative so
    // moving the mouse doesn't bring the cursor back. Force it visible.
    while ShowCursor(True) < 0 do ;
  finally
    NewList.Free;
    FFiltering := False;
  end;
end;

procedure ApplyTBL(HideFlag: Boolean; H: HWND);
var
  TBL: ITaskbarList;
begin
  if H = 0 then Exit;
  try
    TBL := CreateComObject(CLSID_TaskbarList) as ITaskbarList;
    if TBL <> nil then
    begin
      TBL.HrInit;
      if HideFlag then TBL.DeleteTab(H)
      else           TBL.AddTab(H);
    end;
  except
  end;
end;

procedure TMainForm.ApplyHideFromTaskBar;
const
  WS_EX_TOOLWINDOW_FLAG = $00000080;
  WS_EX_APPWINDOW_FLAG  = $00040000;
  COINIT_APARTMENTTHREADED_FLAG = 2;

  procedure ToggleStyle(H: HWND; HideIt: Boolean);
  var Ex: PtrInt;
  begin
    if H = 0 then Exit;
    Ex := GetWindowLongPtr(H, GWL_EXSTYLE);
    if HideIt then
      Ex := (Ex or WS_EX_TOOLWINDOW_FLAG) and not WS_EX_APPWINDOW_FLAG
    else
      Ex := (Ex and not WS_EX_TOOLWINDOW_FLAG) or WS_EX_APPWINDOW_FLAG;
    SetWindowLongPtr(H, GWL_EXSTYLE, Ex);
    SetWindowPos(H, 0, 0, 0, 0, 0,
      SWP_FRAMECHANGED or SWP_NOMOVE or SWP_NOSIZE or
      SWP_NOZORDER or SWP_NOACTIVATE);
  end;

var
  HApp, HMain: HWND;
  HideFlag, MainWasVisible, ComInited: Boolean;
  WinRect: TRect;
begin
  HApp     := Application.Handle;
  HMain    := Self.Handle;
  HideFlag := miHideFromTaskBar.Checked;

  ComInited := Succeeded(CoInitializeEx(nil, COINIT_APARTMENTTHREADED_FLAG));

  // Hiding the VISIBLE main form briefly is what makes Server 2008 R2's
  // shell re-scan the owner chain for taskbar criteria. Save position
  // because re-show can repaint.
  MainWasVisible := IsWindowVisible(HMain);
  GetWindowRect(HMain, WinRect);
  if MainWasVisible then
    ShowWindow(HMain, SW_HIDE);
  if HApp <> 0 then
    ShowWindow(HApp, SW_HIDE);

  // Toggle WS_EX_TOOLWINDOW / WS_EX_APPWINDOW on BOTH potential taskbar
  // carriers — versions differ on which one the shell tracks.
  ToggleStyle(HApp,  HideFlag);
  ToggleStyle(HMain, HideFlag);

  // Re-show BEFORE talking to the shell.
  if HApp <> 0 then
    ShowWindow(HApp, SW_SHOWNOACTIVATE);
  if MainWasVisible then
  begin
    ShowWindow(HMain, SW_SHOWNOACTIVATE);
    SetWindowPos(HMain, 0, WinRect.Left, WinRect.Top,
      WinRect.Right - WinRect.Left, WinRect.Bottom - WinRect.Top,
      SWP_NOZORDER or SWP_NOACTIVATE);
  end;

  // The shell registers a new taskbar entry asynchronously on Show.
  // Drain the message queue + brief wait + drain again so the shell has
  // finished its work; then DeleteTab is guaranteed to target the freshly
  // (re)created entry. Repeat the call a few times — Server 2008 R2's
  // shell sometimes ignores the first DeleteTab while it's still
  // populating.
  Application.ProcessMessages;
  Sleep(50);
  Application.ProcessMessages;
  ApplyTBL(HideFlag, HApp);
  ApplyTBL(HideFlag, HMain);
  Application.ProcessMessages;
  Sleep(50);
  Application.ProcessMessages;
  ApplyTBL(HideFlag, HApp);
  ApplyTBL(HideFlag, HMain);

  if ComInited then CoUninitialize;

  // Restore topmost after the visibility dance — Hide/Show can drop the
  // TOPMOST z-order on older Windows.
  ApplyTopMost;
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

procedure TMainForm.miAboutClick(Sender: TObject);
var
  F: TForm;
  M: TMemo;
  B: TButton;
begin
  F := TForm.Create(Self);
  try
    F.Caption := 'TimeRec — О программе';
    F.Position := poScreenCenter;
    F.BorderStyle := bsSizeable;
    F.Width := 560; F.Height := 540;
    F.Constraints.MinWidth := 400; F.Constraints.MinHeight := 300;

    M := TMemo.Create(F);
    M.Parent := F;
    M.Align := alClient;
    M.BorderSpacing.Around := 8;
    M.ReadOnly := True;
    M.ScrollBars := ssAutoVertical;
    M.WordWrap := True;
    M.Font.Name := 'Consolas';
    M.Font.Height := -13;
    M.Lines.Text :=
      'TimeRec v2 — лёгкий трекер времени для Windows.' + LineEnding +
      'Сборка: ' + Copy({$I %DATE%}, 9, 2) + '.' + Copy({$I %DATE%}, 6, 2) + '.' +
      Copy({$I %DATE%}, 1, 4) + ' ' + Copy({$I %TIME%}, 1, 5) + LineEnding +
      LineEnding +
      'Модель работы (v2)' + LineEnding +
      '  • Таймер запускается автоматически при открытии окна и идёт' + LineEnding +
      '    непрерывно. Нет режима «Стоп».' + LineEnding +
      '  • Кнопка «Готово» фиксирует текущий сегмент: запись попадает' + LineEnding +
      '    в журнал дня, а остаток времени переносится в новый сегмент' + LineEnding +
      '    (счётчик продолжает тикать с этой точки).' + LineEnding +
      '  • После «Готово» поле задания очищается — нужно выбрать' + LineEnding +
      '    или ввести следующее. Пустое имя пишется как «Не учтенно».' + LineEnding +
      LineEnding +
      'Стрелка-длительность под полем задания' + LineEnding +
      '  • Слева: время старта сегмента. Справа у флажка: время «по' + LineEnding +
      '    флагу». В центре стрелки — длительность (Hч Mмин).' + LineEnding +
      '  • Финишный флажок можно перетаскивать ВЛЕВО мышью, чтобы' + LineEnding +
      '    зафиксировать длительность меньше реально прошедшего' + LineEnding +
      '    (типично: «забыл переключить задание»).' + LineEnding +
      '  • Захват только за флажок или время-у-флага; клик в любом' + LineEnding +
      '    другом месте под стрелкой перетаскивает само окно.' + LineEnding +
      '  • Цвет флажка: красный — зафиксирован вручную, зелёный —' + LineEnding +
      '    отслеживает живое время.' + LineEnding +
      '  • Возврат флажка в крайнее правое положение разблокирует' + LineEnding +
      '    его — таймер снова идёт сам.' + LineEnding +
      LineEnding +
      'Что где в окне' + LineEnding +
      LineEnding +
      '   [ ≡ ]   [1ч20мин]   [Задание ▼]   [ Готово ]' + LineEnding +
      '    1          2             3         12:34:56  ← 4' + LineEnding +
      LineEnding +
      '   08:00  ◀───  1ч10мин  ───▷   09:10' + LineEnding +
      '     5             6        7      8' + LineEnding +
      LineEnding +
      '   1 — кнопка ≡, открывает меню настроек.' + LineEnding +
      '   2 — итог по текущему заданию за сегодня.' + LineEnding +
      '   3 — поле задания: поиск и список MRU.' + LineEnding +
      '   4 — кнопка «Готово»; вторая строка — счётчик' + LineEnding +
      '       с момента старта текущего сегмента.' + LineEnding +
      '   5 — время старта текущего сегмента.' + LineEnding +
      '   6 — длительность; можно сдвинуть флажком влево.' + LineEnding +
      '   7 — финишный флажок (драг влево укорачивает).' + LineEnding +
      '   8 — время «у флажка» по часам.' + LineEnding +
      LineEnding +
      'Главное окно' + LineEnding +
      '  • Перетаскивание мышью за любое место (кроме контролов);' + LineEnding +
      '    resize по краям с сохранением пропорций.' + LineEnding +
      '  • Прозрачность: меню «Прозрачность…» открывает слайдер.' + LineEnding +
      '    Может не работать в RDP-сессии или на Windows без' + LineEnding +
      '    композитора (ограничение системы, не приложения).' + LineEnding +
      '  • «Скрыть из панели задач» — окно остаётся видимым,' + LineEnding +
      '    но не появляется в taskbar/Alt+Tab.' + LineEnding +
      '  • Все настройки (позиция, размер, topmost, прозрачность,' + LineEnding +
      '    taskbar-флаг) сохраняются в config.xml.' + LineEnding +
      LineEnding +
      'Поле задачи' + LineEnding +
      '  • Поиск с третьего символа, по подстроке, многословный' + LineEnding +
      '    (порядок слов не важен).' + LineEnding +
      '  • Полный список задач — клик по треугольнику.' + LineEnding +
      '  • Стрелками ↑/↓ навигация по списку без замены текста.' + LineEnding +
      '  • Список отсортирован по последнему использованию (MRU).' + LineEnding +
      LineEnding +
      'Хранение данных' + LineEnding +
      '  • data/YYYY-MM-DD.xml — журнал событий за день.' + LineEnding +
      '  • data/tasks.xml — справочник заданий с видом и lastUsed.' + LineEnding +
      '  • data/current.xml — маркер активной задачи; при аварийном' + LineEnding +
      '    закрытии задача автоматически закрывается на следующем' + LineEnding +
      '    запуске (теряется максимум 10 секунд).' + LineEnding +
      LineEnding +
      'Контекстное меню (правый клик)' + LineEnding +
      '  • Статистика — окно с периодами, выбором задач и видов,' + LineEnding +
      '    табличным и текстовым выводом, копированием в буфер.' + LineEnding +
      '  • Редактирование событий — правка дневных журналов;' + LineEnding +
      '    длительность пересчитывается на лету.' + LineEnding +
      '  • Редактирование заданий — задание имени и вида;' + LineEnding +
      '    удаление с подтверждением.' + LineEnding +
      '  • Папка LazyCure — указание стороннего каталога LazyCure;' + LineEnding +
      '    его файлы .timelog читаются прозрачно для статистики.' + LineEnding +
      '  • Скрыть из панели задач, Поверх всех окон, Прозрачность,' + LineEnding +
      '    О программе, Выход.' + LineEnding +
      LineEnding +
      'Статистика' + LineEnding +
      '  • Периоды: Сегодня / Вчера / Неделя / Месяц / Произвольный.' + LineEnding +
      '  • Мульти-фильтр задач с поиском и сбросом флажков.' + LineEnding +
      '  • Мульти-фильтр по виду (kind) с режимом «исключить»' + LineEnding +
      '    для скрытия категорий типа Обед или Совещания.' + LineEnding +
      '  • Длительности в формате 1ч10мин и HH:MM:SS,' + LineEnding +
      '    сортировка по первому старту.' + LineEnding +
      '  • Текстовый вид + кнопка «Скопировать в буфер».';

    B := TButton.Create(F);
    B.Parent := F;
    B.Caption := 'Закрыть';
    B.ModalResult := mrClose;
    B.Anchors := [akRight, akBottom];
    B.Width := 100; B.Height := 28;
    B.Left := F.ClientWidth - B.Width - 8;
    B.Top := F.ClientHeight - B.Height - 8;
    F.ActiveControl := B;

    F.ShowModal;
  finally
    F.Free;
  end;
end;

procedure TMainForm.miStatsClick(Sender: TObject);
begin
  if StatsForm = nil then
    StatsForm := TStatsForm.Create(Application);
  StatsForm.ShowFor(FDataDir, ResolvedLazyCureDir, FTasksFile);
end;

procedure TMainForm.miEditClick(Sender: TObject);
begin
  if EditForm = nil then
    EditForm := TEditForm.Create(Application);
  EditForm.ShowFor(FDataDir);
end;

procedure TMainForm.miEditTasksClick(Sender: TObject);
begin
  if TasksEditForm = nil then
    TasksEditForm := TTasksEditForm.Create(Application);
  TasksEditForm.ShowFor(FTasksFile);
end;


function TMainForm.ResolvedAudioDir: string;
begin
  if FAudioDir <> '' then
    Result := FAudioDir
  else
    Result := AppDir + 'audio';
end;

procedure TMainForm.miAudioDirClick(Sender: TObject);
var
  D: string;
begin
  D := ResolvedAudioDir;
  if SelectDirectory('Папка для записей аудио (*.mp3)', '', D) then
  begin
    if (D = AppDir + 'audio') or (D = '') then FAudioDir := ''
    else FAudioDir := D;
    SaveConfig;
  end;
end;

procedure TMainForm.miAudioQClick(Sender: TObject);
begin
  if Sender is TMenuItem then
  begin
    FAudioQuality := TAudioQuality(TMenuItem(Sender).Tag);
    TMenuItem(Sender).Checked := True;
    SaveConfig;
  end;
end;

procedure TMainForm.miAudioClick(Sender: TObject);
var
  Mics: TStringList;
  i: Integer;
  Item: TMenuItem;
begin
  // Refresh the mic submenu every time the Audio menu opens.
  miMic.Clear;
  Mics := TStringList.Create;
  try
    FAudioRecorder.ListMics(Mics);
    if Mics.Count = 0 then
    begin
      Item := TMenuItem.Create(miMic);
      Item.Caption := '(нет устройств)';
      Item.Enabled := False;
      miMic.Add(Item);
      Exit;
    end;
    for i := 0 to Mics.Count - 1 do
    begin
      Item := TMenuItem.Create(miMic);
      Item.Caption := Mics[i];
      Item.GroupIndex := 11;
      Item.RadioItem := True;
      Item.AutoCheck := True;
      Item.Checked := (Mics[i] = FMicDevice)
                  or ((FMicDevice = '') and (i = 0));
      Item.OnClick := @MicMenuClick;
      miMic.Add(Item);
    end;
  finally
    Mics.Free;
  end;
end;

procedure TMainForm.MicMenuClick(Sender: TObject);
begin
  if Sender is TMenuItem then
  begin
    FMicDevice := TMenuItem(Sender).Caption;
    SaveConfig;
    // If recording right now, restart so new device takes effect.
    if FAudioRecorder.IsRecording then
    begin
      StopRecording;
      StartRecording;
    end;
  end;
end;

procedure TMainForm.btnMicClick(Sender: TObject);
begin
  SaveConfig;
  if FAudioRecorder.IsRecording then
  begin
    // Toggling sources while recording: restart with new flags.
    StopRecording;
    StartRecording;
  end;
end;

procedure TMainForm.btnSysClick(Sender: TObject);
begin
  SaveConfig;
  if FAudioRecorder.IsRecording then
  begin
    StopRecording;
    StartRecording;
  end;
end;

procedure TMainForm.btnVADClick(Sender: TObject);
begin
  SaveConfig;
  if FAudioRecorder.IsRecording then
  begin
    StopRecording;
    StartRecording;
  end;
end;

procedure TMainForm.AudioListHidden(Sender: TObject);
begin
  btnAudioList.Caption := #$E2#$96#$BE;  // ▾
end;

procedure TMainForm.btnAudioListClick(Sender: TObject);
begin
  if FAudioListForm = nil then
  begin
    FAudioListForm := TAudioListForm.CreateNew(Self);
    FAudioListForm.SetDirs(ResolvedAudioDir, FDataDir);
    FAudioListForm.OnHidden := @AudioListHidden;
  end;
  if FAudioListForm.Visible then
  begin
    FAudioListForm.Hide;
    btnAudioList.Caption := #$E2#$96#$BE;  // ▾
  end
  else
  begin
    FAudioListForm.SetDirs(ResolvedAudioDir, FDataDir);
    FAudioListForm.RefreshList;
    AnchorAudioListForm;
    FAudioListForm.Show;
    btnAudioList.Caption := #$E2#$96#$B4;  // ▴
  end;
end;

procedure TMainForm.AnchorAudioListForm;
var
  NewLeft, NewTop, ScrW: Integer;
begin
  if (FAudioListForm = nil) or (not FAudioListForm.Visible) then Exit;
  // Default: pin the list's left to main's left.
  NewLeft := Left;
  NewTop  := Top + Height;
  // If that would push the list off the right edge of the screen,
  // pin the right edges instead (right of list = right of main).
  ScrW := Screen.WorkAreaWidth;
  if NewLeft + FAudioListForm.Width > ScrW then
    NewLeft := (Left + Width) - FAudioListForm.Width;
  if NewLeft < 0 then NewLeft := 0;
  if (FAudioListForm.Left <> NewLeft) or (FAudioListForm.Top <> NewTop) then
    FAudioListForm.SetBounds(NewLeft, NewTop,
      FAudioListForm.Width, FAudioListForm.Height);
end;

procedure TMainForm.miVadSensClick(Sender: TObject);
var
  Mi: TMenuItem;
begin
  Mi := Sender as TMenuItem;
  Mi.Checked := True;
  if FAudioRecorder <> nil then
    FAudioRecorder.FVadSensitivity := Mi.Tag;
  SaveConfig;
  if FAudioRecorder.IsRecording then
  begin
    StopRecording;
    StartRecording;
  end;
end;

procedure TMainForm.btnRecClick(Sender: TObject);
begin
  DbgLog('btnRecClick enter Down=' + BoolToStr(btnRec.Down, True));
  if btnRec.Down then StartRecording
  else                StopRecording;
  DbgLog('btnRecClick exit');
end;

procedure TMainForm.RefreshMicDropdownVisibility;
var
  Mics: TStringList;
  HasMic: Boolean;
  Count: Integer;
begin
  if FAudioRecorder = nil then Exit;
  Mics := TStringList.Create;
  try
    FAudioRecorder.ListMics(Mics);
    Count := Mics.Count;
  finally
    Mics.Free;
  end;
  HasMic := Count > 0;
  // When the system has no microphone, hide the whole audio row and
  // grey out the audio menu — there's nothing meaningful the user can
  // do here.
  btnMic.Visible     := HasMic;
  btnMicDrop.Visible := HasMic and (Count > 1);
  btnSys.Visible     := HasMic;
  btnRec.Visible     := HasMic;
  btnVAD.Visible     := HasMic;
  lblAudio.Visible   := HasMic;
  miAudio.Enabled    := HasMic;
  if HasMic then
    ClientHeight := 80
  else
    ClientHeight := 54;
  FormResize(nil);
end;

procedure TMainForm.btnMicDropClick(Sender: TObject);
var
  Mics: TStringList;
  i: Integer;
  Item: TMenuItem;
  P: TPoint;
begin
  if FMicDropMenu = nil then
    FMicDropMenu := TPopupMenu.Create(Self);
  FMicDropMenu.Items.Clear;
  Mics := TStringList.Create;
  try
    FAudioRecorder.ListMics(Mics);
    for i := 0 to Mics.Count - 1 do
    begin
      Item := TMenuItem.Create(FMicDropMenu);
      Item.Caption := Mics[i];
      Item.GroupIndex := 12;
      Item.RadioItem := True;
      Item.AutoCheck := True;
      Item.Checked := (Mics[i] = FMicDevice)
                  or ((FMicDevice = '') and (i = 0));
      Item.OnClick := @MicDropMenuClick;
      FMicDropMenu.Items.Add(Item);
    end;
  finally
    Mics.Free;
  end;
  P.X := 0;
  P.Y := btnMicDrop.Height;
  P := btnMicDrop.ClientToScreen(P);
  FMicDropMenu.PopUp(P.X, P.Y);
end;

procedure TMainForm.MicDropMenuClick(Sender: TObject);
begin
  if Sender is TMenuItem then
  begin
    FMicDevice := TMenuItem(Sender).Caption;
    SaveConfig;
    if FAudioRecorder.IsRecording then
    begin
      StopRecording;
      StartRecording;
    end;
  end;
end;

procedure TMainForm.StartRecording;
var
  Path: string;
begin
  DbgLog('StartRecording enter');
  try
    if FAudioRecorder = nil then begin DbgLog('  recorder nil'); Exit; end;
    if FAudioRecorder.IsRecording then begin DbgLog('  already recording'); Exit; end;
    if not (btnMic.Down or btnSys.Down) then
      btnMic.Down := True;
    if not FAudioRecorder.FFmpegAvailable then
    begin
      ShowMessage('ffmpeg.exe не найден. Положите его рядом с программой '
                + 'или установите в PATH.');
      btnRec.Down := False;
      Exit;
    end;
    ForceDirectories(ResolvedAudioDir);
    Path := ResolvedAudioDir + PathDelim +
            FormatDateTime('yyyymmdd_hhnnss', Now) + '.mp3';
    DbgLog('  path=' + Path + ' mic=' + BoolToStr(btnMic.Down, True)
         + ' sys=' + BoolToStr(btnSys.Down, True));
    if FMicDevice = '' then
    begin
      FMicDevice := FAudioRecorder.DetectFirstMic;
      DbgLog('  detected mic: "' + FMicDevice + '"');
    end;
    if FAudioRecorder.Start(Path, btnMic.Down, btnSys.Down,
         FAudioQuality, FMicDevice, btnVAD.Down) then
    begin
      DbgLog('  Start returned True; IsRecording=' + BoolToStr(FAudioRecorder.IsRecording, True));
      FAudioFilesForSegment.Add(Path);
      FAudioPaused := False;
      FAudioPausedTotalMs := 0;
      FLastAudioFileSize := 0;
      FAudioUnchangedTicks := 0;
      FRecStartTickMs := GetTickCount64;
      btnRec.Font.Color := clRed;
      btnRec.Font.Style := [fsBold];
      btnRec.Caption := #$E2#$97#$8F + ' REC';
      btnRec.Invalidate;
      UpdateAudioStatus;
    end
    else
    begin
      DbgLog('  Start returned False');
      btnRec.Down := False;
    end;
  except
    on E: Exception do
    begin
      DbgLog('  EXCEPTION: ' + E.ClassName + ' / ' + E.Message);
      ShowMessage('Старт записи: ' + E.ClassName + ' / ' + E.Message);
      btnRec.Down := False;
    end;
  end;
  DbgLog('StartRecording exit');
end;

procedure TMainForm.StopRecording;
begin
  DbgLog('StopRecording enter');
  try
    if FAudioRecorder = nil then begin DbgLog('  recorder nil'); Exit; end;
    if not FAudioRecorder.IsRecording then
    begin
      DbgLog('  not recording, reset buttons');
      btnRec.Font.Color := clWindowText;
      btnRec.Font.Style := [];
      btnRec.Caption := #$E2#$97#$8F + ' REC';
      btnRec.Invalidate;
      Exit;
    end;
    DbgLog('  calling Stop');
    FAudioRecorder.Stop;
    DbgLog('  Stop returned, resetting visuals');
    btnRec.Font.Color := clWindowText;
    btnRec.Font.Style := [];
    btnRec.Caption := #$E2#$97#$8F + ' REC';
    btnRec.Invalidate;
    UpdateAudioStatus;
  except
    on E: Exception do
    begin
      DbgLog('  EXCEPTION: ' + E.ClassName + ' / ' + E.Message);
      ShowMessage('Стоп записи: ' + E.ClassName + ' / ' + E.Message);
    end;
  end;
  DbgLog('StopRecording exit');
end;

procedure TMainForm.UpdateAudioStatus;
var
  S: string;
  Sec: Integer;
begin
  if FAudioRecorder.IsRecording then
  begin
    Sec := FAudioRecorder.ElapsedSec;
    S := Format('запись %.2d:%.2d', [Sec div 60, Sec mod 60]);
    if FAudioFilesForSegment.Count > 1 then
      S := S + Format(' (#%d)', [FAudioFilesForSegment.Count]);
  end
  else
  begin
    if FAudioFilesForSegment.Count > 0 then
      S := Format('к задаче: %d файл(ов)', [FAudioFilesForSegment.Count])
    else
      S := '';
  end;
  lblAudio.Caption := S;
end;

function TMainForm.ResolvedLazyCureDir: string;
begin
  if FLazyCureDir <> '' then
    Result := FLazyCureDir
  else
    Result := FDataDir + PathDelim + 'LazyCure';
end;

procedure TMainForm.miLazyCureDirClick(Sender: TObject);
var
  D: string;
begin
  D := ResolvedLazyCureDir;
  if SelectDirectory('Папка с файлами LazyCure (*.timelog)', '', D) then
  begin
    if (D = FDataDir + PathDelim + 'LazyCure') or (D = '') then
      FLazyCureDir := ''
    else
      FLazyCureDir := D;
    SaveConfig;
  end;
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

procedure TMainForm.OpacityTrackChange(Sender: TObject);
var
  V: Integer;
begin
  if not (Sender is TTrackBar) then Exit;
  V := TTrackBar(Sender).Position;
  if V < 10 then V := 10;
  if V > 100 then V := 100;
  FOpacity := V;
  ApplyOpacity(V);
  if FOpacityLbl <> nil then
    FOpacityLbl.Caption := 'Видимость окна: ' + IntToStr(V) + '%';
end;

procedure TMainForm.miOpacityClick(Sender: TObject);
var
  F: TForm;
  TB: TTrackBar;
  L: TLabel;
  B: TButton;
  OldOpacity: Integer;
begin
  OldOpacity := FOpacity;
  F := TForm.Create(Self);
  try
    F.Caption := 'Прозрачность';
    F.BorderStyle := bsToolWindow;
    F.FormStyle := fsStayOnTop;
    F.Position := poScreenCenter;
    F.Width := 300;
    F.Height := 110;

    L := TLabel.Create(F);
    L.Parent := F;
    L.SetBounds(12, 10, 270, 16);
    L.Caption := 'Видимость окна: ' + IntToStr(FOpacity) + '%';
    FOpacityLbl := L;

    TB := TTrackBar.Create(F);
    TB.Parent := F;
    TB.SetBounds(8, 30, 280, 32);
    TB.Min := 10;
    TB.Max := 100;
    TB.Frequency := 5;
    TB.Position := FOpacity;
    TB.OnChange := @OpacityTrackChange;

    B := TButton.Create(F);
    B.Parent := F;
    B.SetBounds(200, 72, 88, 28);
    B.Caption := 'Закрыть';
    B.ModalResult := mrClose;
    B.Default := True;
    F.ActiveControl := TB;

    if F.ShowModal <> mrCancel then
      SaveConfig
    else
    begin
      // Revert on cancel (Esc) — restore previous opacity.
      FOpacity := OldOpacity;
      ApplyOpacity(FOpacity);
    end;
  finally
    FOpacityLbl := nil;
    F.Free;
  end;
end;

function TMainForm.CheckOpacitySupported: Boolean;
begin
  // Always enabled. Auto-detection (DwmIsCompositionEnabled,
  // SM_REMOTESESSION) gave false negatives on configurations where the
  // user reported transparency actually worked. If the result is bad on
  // a given system, the user can simply not use the menu — better than
  // hiding it incorrectly.
  Result := True;
end;

procedure TMainForm.ApplyOpacity(APercent: Integer);
const
  WS_EX_LAYERED_FLAG    = $00080000;
  WS_EX_COMPOSITED_FLAG = $02000000;
  LWA_ALPHA             = $00000002;
  TransientFlags        = WS_EX_LAYERED_FLAG or WS_EX_COMPOSITED_FLAG;
var
  H: HWND;
  Ex, NewEx: PtrInt;
  Alpha: Byte;
begin
  if not HandleAllocated then Exit;
  // Skip silently on systems without DWM composition (Server 2008 R2
  // without Desktop Experience) — the API succeeds but the result
  // shows opaque/grey artifacts instead of true transparency.
  if not FOpacitySupported then Exit;
  H := Self.Handle;
  Alpha := Round(255 * APercent / 100);
  Ex := GetWindowLongPtr(H, GWL_EXSTYLE);
  if APercent >= 100 then
    NewEx := Ex and not TransientFlags
  else
    NewEx := Ex or TransientFlags;

  if NewEx <> Ex then
  begin
    SetWindowLongPtr(H, GWL_EXSTYLE, NewEx);
    SetWindowPos(H, 0, 0, 0, 0, 0,
      SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE or
      SWP_FRAMECHANGED);
  end;
  if APercent < 100 then
    SetLayeredWindowAttributes(H, 0, Alpha, LWA_ALPHA);
  RedrawWindow(H, nil, 0,
    RDW_INVALIDATE or RDW_ALLCHILDREN or RDW_UPDATENOW or RDW_FRAME);
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
      S := Root.GetAttribute('width');  if TryStrToInt(S, V) then Width  := V;
      S := Root.GetAttribute('height'); if TryStrToInt(S, V) then Height := V;
      // Normalize: v3 form is 340x80 (audio row added below the slider).
      if Height < 80 then Height := 80;
      Width := Round(Height * 340 / 80);
      S := Root.GetAttribute('topMost');
      if S = '0' then
        miTopMost.Checked := False;
      S := Root.GetAttribute('hideFromTaskBar');
      if S = '1' then
        miHideFromTaskBar.Checked := True;
      S := Root.GetAttribute('opacity');
      if TryStrToInt(S, V) and (V >= 10) and (V <= 100) then
        FOpacity := V;
      FLazyCureDir := Root.GetAttribute('lazyCureDir');
      FAudioDir := Root.GetAttribute('audioDir');
      FMicDevice := Root.GetAttribute('micDevice');
      S := Root.GetAttribute('audioQuality');
      if TryStrToInt(S, V) and (V >= 0) and (V <= 2) then
        FAudioQuality := TAudioQuality(V);
      S := Root.GetAttribute('recMic');
      if S = '0' then btnMic.Down := False else btnMic.Down := True;
      S := Root.GetAttribute('recSys');
      if S = '1' then btnSys.Down := True else btnSys.Down := False;
      S := Root.GetAttribute('vad');
      if S = '1' then btnVAD.Down := True else btnVAD.Down := False;
      S := Root.GetAttribute('vadSens');
      if TryStrToInt(S, V) then
      begin
        if FAudioRecorder <> nil then
          FAudioRecorder.FVadSensitivity := V;
        case V of
          -8: miVadHigh.Checked := True;
           8: miVadLow.Checked  := True;
        else
          miVadMid.Checked := True;
        end;
      end;
      S := Root.GetAttribute('taskDropRows');
      if TryStrToInt(S, V) and (V >= 5) and (V <= 60) then
        cbTask.DropDownCount := V;
      case FAudioQuality of
        aqLow:  miAudioQLow.Checked := True;
        aqMid:  miAudioQMid.Checked := True;
        aqHigh: miAudioQHigh.Checked := True;
      end;
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
    if FLazyCureDir <> '' then
      Root.SetAttribute('lazyCureDir', FLazyCureDir);
    if FAudioDir <> '' then
      Root.SetAttribute('audioDir', FAudioDir);
    if FMicDevice <> '' then
      Root.SetAttribute('micDevice', FMicDevice);
    Root.SetAttribute('audioQuality', IntToStr(Ord(FAudioQuality)));
    if btnMic.Down then Root.SetAttribute('recMic', '1')
                   else Root.SetAttribute('recMic', '0');
    if btnSys.Down then Root.SetAttribute('recSys', '1')
                   else Root.SetAttribute('recSys', '0');
    if btnVAD.Down then Root.SetAttribute('vad', '1')
                   else Root.SetAttribute('vad', '0');
    if FAudioRecorder <> nil then
      Root.SetAttribute('vadSens', IntToStr(FAudioRecorder.FVadSensitivity));
    Root.SetAttribute('taskDropRows', IntToStr(cbTask.DropDownCount));
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

procedure TMainForm.AppendEntry(const ATask: string; AStart, AEnd: TDateTime;
  AudioFiles: TStrings = nil);

  procedure WriteSingle(const SDT, EDT: TDateTime; AttachAudio: Boolean);
  var
    Doc: TXMLDocument;
    Root, El, AEl: TDOMElement;
    LogFile: string;
    DurMS: Int64;
    i: Integer;
  begin
    if EDT <= SDT then Exit;
    // Per-day file based on the segment's START date (not today's date,
    // which previously misfiled split entries into the wrong day).
    LogFile := FDataDir + PathDelim +
               FormatDateTime('yyyy-mm-dd', SDT) + '.xml';
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
        Root.SetAttribute('date', FormatDateTime('yyyy-mm-dd', SDT));
        Doc.AppendChild(Root);
      end;
      DurMS := Round((EDT - SDT) * 86400000);
      El := Doc.CreateElement('entry');
      El.SetAttribute('task', ATask);
      El.SetAttribute('start', FormatDateTime(IsoFmt, SDT));
      El.SetAttribute('end',   FormatDateTime(IsoFmt, EDT));
      El.SetAttribute('duration', FormatDateTime(TimeFmt, EDT - SDT));
      El.SetAttribute('durationMs', IntToStr(DurMS));
      if AttachAudio and (AudioFiles <> nil) then
        for i := 0 to AudioFiles.Count - 1 do
        begin
          AEl := Doc.CreateElement('audio');
          AEl.SetAttribute('path', AudioFiles[i]);
          El.AppendChild(AEl);
        end;
      Root.AppendChild(El);
      WriteXMLFile(Doc, LogFile);
    finally
      Doc.Free;
    end;
  end;

var
  CurStart, NextMidnight: TDateTime;
  IsFirst: Boolean;
begin
  CurStart := AStart;
  IsFirst := True;
  while CurStart < AEnd do
  begin
    NextMidnight := Trunc(CurStart) + 1.0;
    if AEnd <= NextMidnight then
    begin
      // Attach audio only to the first (or only) chunk to avoid duplication.
      WriteSingle(CurStart, AEnd, IsFirst);
      Break;
    end;
    WriteSingle(CurStart, NextMidnight, IsFirst);
    IsFirst := False;
    CurStart := NextMidnight;
  end;
end;

end.
