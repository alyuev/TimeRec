unit uaitext;

// Transcript viewer/editor. Non-modal. Renders timestamped .txt as a
// two-column grid (time | text). Plain (no-bracket) lines still
// display in the same grid with an empty time cell. The user edits the
// text column; the original time-bracket text is preserved verbatim
// for save. A toolbar button toggles the time column's visibility.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, Forms, Controls, StdCtrls, Grids, ExtCtrls,
  Graphics, Clipbrd, Dialogs, Windows, ShellApi;

procedure ShowTranscriptFile(const Path: string);
procedure SetDefaultShowTimes(Value: Boolean);
procedure SetFFmpegPath(const Path: string);

implementation

var
  GShowTimesDefault: Boolean = True;
  GOpen: TStringList = nil;
  GFFmpeg: string = '';

procedure SetFFmpegPath(const Path: string);
begin
  GFFmpeg := Path;
end;

function IsLikelyCbrMp3(const Path: string): Boolean;
// Heuristic: VBR/ABR mp3s carry a "Xing" or "Info" tag in the first
// frame's padding (LAME and most encoders write it). If absent in the
// first 1 KB we assume CBR — that's what our recorder makes (write_xing 0).
var
  FS: TFileStream;
  Buf: array[0..1023] of Byte;
  N, i: Integer;
begin
  Result := False;
  if not FileExists(Path) then Exit;
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if FS.Size <= 0 then Exit;
      N := FS.Read(Buf, SizeOf(Buf));
    finally
      FS.Free;
    end;
  except
    Exit;
  end;
  for i := 0 to N - 4 do
    if ((Buf[i] = Ord('X')) and (Buf[i+1] = Ord('i')) and
        (Buf[i+2] = Ord('n')) and (Buf[i+3] = Ord('g'))) or
       ((Buf[i] = Ord('I')) and (Buf[i+1] = Ord('n')) and
        (Buf[i+2] = Ord('f')) and (Buf[i+3] = Ord('o'))) then
      Exit(False);
  Result := True;
end;

function ReencodeToCbr(const SrcMp3, DstMp3: string): Boolean;
var
  P: TProcess;
begin
  Result := False;
  if (GFFmpeg = '') or not FileExists(GFFmpeg) then Exit;
  P := TProcess.Create(nil);
  try
    P.Executable := GFFmpeg;
    P.Parameters.Add('-y');
    P.Parameters.Add('-hide_banner');
    P.Parameters.Add('-nostats');
    P.Parameters.Add('-loglevel'); P.Parameters.Add('error');
    P.Parameters.Add('-i'); P.Parameters.Add(SrcMp3);
    P.Parameters.Add('-c:a'); P.Parameters.Add('libmp3lame');
    P.Parameters.Add('-b:a'); P.Parameters.Add('64k');
    P.Parameters.Add('-minrate'); P.Parameters.Add('64k');
    P.Parameters.Add('-maxrate'); P.Parameters.Add('64k');
    P.Parameters.Add('-bufsize'); P.Parameters.Add('64k');
    P.Parameters.Add('-write_xing'); P.Parameters.Add('0');
    P.Parameters.Add(DstMp3);
    P.Options := [poUsePipes, poNoConsole, poWaitOnExit];
    try
      P.Execute;
      Result := (P.ExitStatus = 0) and FileExists(DstMp3);
    except end;
  finally
    P.Free;
  end;
end;

type
  TLineRec = class
    Bracket: string;     // verbatim "[HH:MM:SS.mmm --> HH:MM:SS.mmm]" or ''
    TimeShort: string;   // displayed in col 0, e.g. "00:15"
    Text: string;        // edited in col 1
    StartMs: Int64;      // parsed start time in ms for seek
  end;

  TAITextForm = class(TForm)
  public
    FPath: string;
    FAudioPath: string;
    FMciAlias: string;
    FMciOpened: Boolean;
    FTempAudio: string;  // CBR re-encode for accurate MCI seek
    FPlayTimer: TTimer;
    FCurrentPlayRow: Integer;
    Grid: TStringGrid;
    Toolbar: TPanel;
    btnPlay, btnStop, btnCopy, btnSave, btnToggleTime, btnClose: TButton;
    Dirty: Boolean;
    ShowTimes: Boolean;
    procedure DoPlay(Sender: TObject);
    procedure DoStop(Sender: TObject);
    procedure DoCopy(Sender: TObject);
    procedure DoSave(Sender: TObject);
    procedure DoToggleTime(Sender: TObject);
    procedure DoCloseBtn(Sender: TObject);
    procedure DoFormClose(Sender: TObject; var ACloseAction: TCloseAction);
    procedure DoGridSelectEditor(Sender: TObject; aCol, aRow: Integer;
      var Editor: TWinControl);
    procedure DoGridEditingDone(Sender: TObject);
    procedure DoGridMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure DoGridPrepareCanvas(Sender: TObject; aCol, aRow: Integer;
      aState: TGridDrawState);
    procedure DoPlayTimer(Sender: TObject);
    procedure UpdateCaption;
    procedure ApplyShowTimes;
    procedure LoadFromFile;
    procedure SaveToFile;
    procedure McOpen;
    procedure McClose;
    procedure McPlayFromMs(StartMs: Int64);
    function McGetPositionMs: Int64;
    function McIsPlaying: Boolean;
    function RowRec(Row: Integer): TLineRec;
  end;

function mciSendStringW(lpCmd, lpReturnString: PWideChar;
  uReturnLength: UINT; hWnd: HWND): DWORD; stdcall;
  external 'winmm.dll' name 'mciSendStringW';

procedure SetDefaultShowTimes(Value: Boolean);
begin
  GShowTimesDefault := Value;
end;

// Parse "[HH:MM:SS.mmm --> HH:MM:SS.mmm]   text" → (bracket, short-time, text).
// Returns False if the line doesn't have a leading bracket.
function ParseTimedLine(const Line: string; out BracketOut, TimeShort,
  TextOut: string): Boolean;
var
  RBracket: Integer;
  HH, MM, SS: string;
begin
  Result := False;
  BracketOut := ''; TimeShort := ''; TextOut := Line;
  if (Length(Line) < 2) or (Line[1] <> '[') then Exit;
  RBracket := Pos(']', Line);
  if RBracket < 10 then Exit;  // need at least "[HH:MM:SS"
  HH := Copy(Line, 2, 2);
  MM := Copy(Line, 5, 2);
  SS := Copy(Line, 8, 2);
  if HH = '00' then TimeShort := MM + ':' + SS
  else TimeShort := HH + ':' + MM + ':' + SS;
  BracketOut := Copy(Line, 1, RBracket);
  TextOut := Trim(Copy(Line, RBracket + 1, MaxInt));
  Result := True;
end;

procedure TAITextForm.UpdateCaption;
begin
  Caption := 'TimeRec — Расшифровка: ' + ExtractFileName(FPath);
  if Dirty then Caption := Caption + '   *';
end;

procedure TAITextForm.ApplyShowTimes;
begin
  if ShowTimes then
  begin
    Grid.ColWidths[0] := 64;
    btnToggleTime.Caption := 'Скрыть время';
  end
  else
  begin
    Grid.ColWidths[0] := 0;
    btnToggleTime.Caption := 'Показать время';
  end;
end;

function TAITextForm.RowRec(Row: Integer): TLineRec;
begin
  Result := nil;
  if (Row < 1) or (Row >= Grid.RowCount) then Exit;
  Result := TLineRec(Grid.Objects[1, Row]);
end;

procedure TAITextForm.LoadFromFile;
var
  Lines: TStringList;
  i: Integer;
  Bracket, TimeShort, Body, Line: string;
  Rec: TLineRec;
begin
  Lines := TStringList.Create;
  try
    if FileExists(FPath) then Lines.LoadFromFile(FPath);
    Grid.RowCount := Lines.Count + 1;
    Grid.Cells[0, 0] := 'Время';
    Grid.Cells[1, 0] := 'Текст';
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if Line = '' then begin Grid.RowCount := Grid.RowCount - 1; Continue; end;
      ParseTimedLine(Line, Bracket, TimeShort, Body);
      Rec := TLineRec.Create;
      Rec.Bracket := Bracket;
      Rec.TimeShort := TimeShort;
      Rec.Text := Body;
      Rec.StartMs := 0;
      // Parse start time HH:MM:SS.mmm from inside the bracket.
      if Length(Bracket) >= 13 then
      begin
        Rec.StartMs :=
          StrToIntDef(Copy(Bracket, 2, 2), 0) * 3600000 +
          StrToIntDef(Copy(Bracket, 5, 2), 0) * 60000 +
          StrToIntDef(Copy(Bracket, 8, 2), 0) * 1000 +
          StrToIntDef(Copy(Bracket, 11, 3), 0);
      end;
      Grid.Cells[0, i + 1] := TimeShort;
      Grid.Cells[1, i + 1] := Body;
      Grid.Objects[1, i + 1] := Rec;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TAITextForm.SaveToFile;
var
  Lines: TStringList;
  i: Integer;
  Rec: TLineRec;
  L: string;
begin
  Lines := TStringList.Create;
  try
    for i := 1 to Grid.RowCount - 1 do
    begin
      Rec := RowRec(i);
      if Rec = nil then Continue;
      Rec.Text := Grid.Cells[1, i];
      if Rec.Bracket <> '' then
        L := Rec.Bracket + '   ' + Rec.Text
      else
        L := Rec.Text;
      Lines.Add(L);
    end;
    Lines.SaveToFile(FPath);
  finally
    Lines.Free;
  end;
  Dirty := False;
  btnSave.Enabled := False;
  UpdateCaption;
end;

procedure TAITextForm.McOpen;
var
  Cmd: UnicodeString;
  Err: array[0..255] of WideChar;
  Playable, CbrPath: string;
begin
  if FMciOpened then Exit;
  if (FAudioPath = '') or not FileExists(FAudioPath) then Exit;

  // MCI's mpegvideo driver seeks via byte-offset * average bit rate,
  // which is wildly inaccurate on VBR mp3s (ours typically are, after
  // libmp3lame default encoding). Pre-emptively re-encode to a CBR
  // copy so seek/position are sample-accurate.
  Playable := FAudioPath;
  if SameText(ExtractFileExt(FAudioPath), '.mp3') and (GFFmpeg <> '')
     and not IsLikelyCbrMp3(FAudioPath) then
  begin
    CbrPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
      'timerec_cbr_' + IntToHex(PtrUInt(Self), 8) + '.mp3';
    if ReencodeToCbr(FAudioPath, CbrPath) then
    begin
      FTempAudio := CbrPath;
      Playable := CbrPath;
    end;
  end;

  // Pre-emptive close in case alias is somehow leftover.
  mciSendStringW(PWideChar(UnicodeString('close ' + FMciAlias)),
    nil, 0, 0);
  Cmd := UnicodeString('open "' + Playable + '" type mpegvideo alias ' +
    FMciAlias);
  if mciSendStringW(PWideChar(Cmd), @Err[0], Length(Err), 0) <> 0 then
  begin
    Cmd := UnicodeString('open "' + Playable + '" alias ' + FMciAlias);
    if mciSendStringW(PWideChar(Cmd), @Err[0], Length(Err), 0) <> 0 then
      Exit;
  end;
  mciSendStringW(PWideChar(UnicodeString('set ' + FMciAlias +
    ' time format ms')), nil, 0, 0);
  FMciOpened := True;
end;

procedure TAITextForm.McClose;
begin
  if FMciOpened then
  begin
    mciSendStringW(PWideChar(UnicodeString('stop ' + FMciAlias)), nil, 0, 0);
    mciSendStringW(PWideChar(UnicodeString('close ' + FMciAlias)), nil, 0, 0);
    FMciOpened := False;
  end;
  if (FTempAudio <> '') and FileExists(FTempAudio) then
  begin
    SysUtils.DeleteFile(FTempAudio);
    FTempAudio := '';
  end;
end;

procedure TAITextForm.McPlayFromMs(StartMs: Int64);
var
  Cmd: UnicodeString;
begin
  McOpen;
  if not FMciOpened then
  begin
    // Fall back to system player if MCI couldn't load.
    if FAudioPath <> '' then
      ShellExecuteW(0, nil, PWideChar(UnicodeString(FAudioPath)),
        nil, nil, 1);
    Exit;
  end;
  mciSendStringW(PWideChar(UnicodeString('stop ' + FMciAlias)),
    nil, 0, 0);
  Cmd := UnicodeString('play ' + FMciAlias + ' from ' + IntToStr(StartMs));
  mciSendStringW(PWideChar(Cmd), nil, 0, 0);
  if FPlayTimer <> nil then FPlayTimer.Enabled := True;
end;

function TAITextForm.McGetPositionMs: Int64;
var
  Buf: array[0..63] of WideChar;
  S: string;
begin
  Result := -1;
  if not FMciOpened then Exit;
  FillChar(Buf, SizeOf(Buf), 0);
  if mciSendStringW(PWideChar(UnicodeString('status ' + FMciAlias +
       ' position')), @Buf[0], Length(Buf), 0) <> 0 then Exit;
  S := UTF8Encode(WideString(Buf));
  if not TryStrToInt64(Trim(S), Result) then Result := -1;
end;

function TAITextForm.McIsPlaying: Boolean;
var
  Buf: array[0..31] of WideChar;
  S: string;
begin
  Result := False;
  if not FMciOpened then Exit;
  FillChar(Buf, SizeOf(Buf), 0);
  if mciSendStringW(PWideChar(UnicodeString('status ' + FMciAlias + ' mode')),
       @Buf[0], Length(Buf), 0) <> 0 then Exit;
  S := UTF8Encode(WideString(Buf));
  Result := SameText(Trim(S), 'playing');
end;

procedure TAITextForm.DoPlayTimer(Sender: TObject);
var
  PosMs: Int64;
  i, NewRow, Vis, TopGoal: Integer;
  Rec: TLineRec;
begin
  if not McIsPlaying then
  begin
    FPlayTimer.Enabled := False;
    Exit;
  end;
  PosMs := McGetPositionMs;
  if PosMs < 0 then Exit;
  NewRow := FCurrentPlayRow;
  for i := 1 to Grid.RowCount - 1 do
  begin
    Rec := RowRec(i);
    if Rec = nil then Continue;
    if Rec.StartMs > PosMs then Break;
    NewRow := i;
  end;
  if NewRow <> FCurrentPlayRow then
  begin
    FCurrentPlayRow := NewRow;
    Grid.Invalidate;
    // Auto-scroll if off-screen.
    Vis := Grid.VisibleRowCount;
    if Vis < 1 then Vis := 1;
    if (NewRow < Grid.TopRow) or (NewRow > Grid.TopRow + Vis - 1) then
    begin
      TopGoal := NewRow - Vis div 2;
      if TopGoal < 1 then TopGoal := 1;
      Grid.TopRow := TopGoal;
    end;
  end;
end;

procedure TAITextForm.DoGridPrepareCanvas(Sender: TObject; aCol, aRow: Integer;
  aState: TGridDrawState);
begin
  if (aRow = FCurrentPlayRow) and (aRow > 0) and
     not (gdSelected in aState) then
    Grid.Canvas.Brush.Color := $00B0F0FF;  // soft yellow
end;

procedure TAITextForm.DoPlay(Sender: TObject);
var
  Rec: TLineRec;
  StartMs: Int64;
begin
  if (FAudioPath = '') or not FileExists(FAudioPath) then
  begin
    ShowMessage('Аудиофайл не найден.');
    Exit;
  end;
  StartMs := 0;
  Rec := RowRec(Grid.Row);
  if Rec <> nil then StartMs := Rec.StartMs;
  McPlayFromMs(StartMs);
end;

procedure TAITextForm.DoStop(Sender: TObject);
begin
  if FMciOpened then
    mciSendStringW(PWideChar(UnicodeString('stop ' + FMciAlias)),
      nil, 0, 0);
  if FPlayTimer <> nil then FPlayTimer.Enabled := False;
  if FCurrentPlayRow <> 0 then
  begin
    FCurrentPlayRow := 0;
    Grid.Invalidate;
  end;
end;

procedure TAITextForm.DoGridMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  C, R: Integer;
  Rec: TLineRec;
begin
  if Button <> mbLeft then Exit;
  Grid.MouseToCell(X, Y, C, R);
  if (C = 0) and (R >= 1) and (R < Grid.RowCount) then
  begin
    Rec := RowRec(R);
    if (Rec <> nil) and (FAudioPath <> '') and FileExists(FAudioPath) then
      McPlayFromMs(Rec.StartMs);
  end;
end;

procedure TAITextForm.DoCopy(Sender: TObject);
var
  i: Integer;
  S: string;
  Rec: TLineRec;
begin
  S := '';
  for i := 1 to Grid.RowCount - 1 do
  begin
    Rec := RowRec(i);
    if Rec = nil then Continue;
    if S <> '' then S := S + LineEnding;
    S := S + Grid.Cells[1, i];
  end;
  Clipboard.AsText := S;
end;

procedure TAITextForm.DoSave(Sender: TObject);
begin
  SaveToFile;
end;

procedure TAITextForm.DoToggleTime(Sender: TObject);
begin
  ShowTimes := not ShowTimes;
  GShowTimesDefault := ShowTimes;
  ApplyShowTimes;
end;

procedure TAITextForm.DoCloseBtn(Sender: TObject);
begin
  Close;
end;

procedure TAITextForm.DoGridSelectEditor(Sender: TObject; aCol, aRow: Integer;
  var Editor: TWinControl);
begin
  // Time column is read-only.
  if aCol = 0 then Editor := nil;
end;

procedure TAITextForm.DoGridEditingDone(Sender: TObject);
var
  Rec: TLineRec;
begin
  Rec := RowRec(Grid.Row);
  if Rec = nil then Exit;
  if Grid.Cells[1, Grid.Row] <> Rec.Text then
  begin
    if not Dirty then
    begin
      Dirty := True;
      btnSave.Enabled := True;
      UpdateCaption;
    end;
  end;
end;

procedure TAITextForm.DoFormClose(Sender: TObject;
  var ACloseAction: TCloseAction);
var
  idx, i: Integer;
  Rec: TLineRec;
begin
  if Dirty then
    case MessageDlg('Сохранить изменения в файле?' + LineEnding +
           ExtractFileName(FPath),
         mtConfirmation, [mbYes, mbNo, mbCancel], 0) of
      mrYes:    SaveToFile;
      mrCancel: begin ACloseAction := caNone; Exit; end;
    end;
  McClose;
  if GOpen <> nil then
  begin
    idx := GOpen.IndexOf(FPath);
    if idx >= 0 then GOpen.Delete(idx);
  end;
  for i := 1 to Grid.RowCount - 1 do
  begin
    Rec := RowRec(i);
    if Rec <> nil then Rec.Free;
  end;
  ACloseAction := caFree;
end;

procedure ShowTranscriptFile(const Path: string);
var
  F: TAITextForm;
  i: Integer;
  Mp3: string;
begin
  if GOpen = nil then GOpen := TStringList.Create;
  i := GOpen.IndexOf(Path);
  if i >= 0 then
  begin
    F := TAITextForm(GOpen.Objects[i]);
    F.BringToFront;
    if F.WindowState = wsMinimized then F.WindowState := wsNormal;
    F.Show;
    Exit;
  end;
  F := TAITextForm.CreateNew(Application);
  F.FPath := Path;
  Mp3 := ChangeFileExt(Path, '.mp3');
  if FileExists(Mp3) then F.FAudioPath := Mp3;
  // Use the form's address as a unique MCI alias so multiple open
  // viewers don't collide.
  F.FMciAlias := 'trec_' + IntToHex(PtrUInt(F), 8);
  F.FMciOpened := False;
  F.FCurrentPlayRow := 0;
  F.FPlayTimer := TTimer.Create(F);
  F.FPlayTimer.Interval := 150;
  F.FPlayTimer.Enabled := False;
  F.FPlayTimer.OnTimer := @F.DoPlayTimer;
  F.Dirty := False;
  F.ShowTimes := GShowTimesDefault;
  F.BorderStyle := bsSizeable;
  F.Position := poScreenCenter;
  F.ClientWidth := 760;
  F.ClientHeight := 520;
  F.OnClose := @F.DoFormClose;

  F.Toolbar := TPanel.Create(F);
  F.Toolbar.Parent := F;
  F.Toolbar.Align := alTop;
  F.Toolbar.Height := 36;
  F.Toolbar.BevelOuter := bvNone;

  F.btnPlay := TButton.Create(F);
  F.btnPlay.Parent := F.Toolbar;
  F.btnPlay.SetBounds(8, 4, 80, 28);
  F.btnPlay.Caption := '▶ Play';
  F.btnPlay.OnClick := @F.DoPlay;
  F.btnPlay.Enabled := F.FAudioPath <> '';

  F.btnStop := TButton.Create(F);
  F.btnStop.Parent := F.Toolbar;
  F.btnStop.SetBounds(94, 4, 80, 28);
  F.btnStop.Caption := '■ Стоп';
  F.btnStop.OnClick := @F.DoStop;
  F.btnStop.Enabled := F.FAudioPath <> '';

  F.btnCopy := TButton.Create(F);
  F.btnCopy.Parent := F.Toolbar;
  F.btnCopy.SetBounds(182, 4, 160, 28);
  F.btnCopy.Caption := 'Скопировать в буфер';
  F.btnCopy.OnClick := @F.DoCopy;

  F.btnSave := TButton.Create(F);
  F.btnSave.Parent := F.Toolbar;
  F.btnSave.SetBounds(350, 4, 110, 28);
  F.btnSave.Caption := 'Сохранить';
  F.btnSave.Enabled := False;
  F.btnSave.OnClick := @F.DoSave;

  F.btnToggleTime := TButton.Create(F);
  F.btnToggleTime.Parent := F.Toolbar;
  F.btnToggleTime.SetBounds(468, 4, 140, 28);
  F.btnToggleTime.OnClick := @F.DoToggleTime;

  F.btnClose := TButton.Create(F);
  F.btnClose.Parent := F.Toolbar;
  F.btnClose.Anchors := [akRight, akTop];
  F.btnClose.SetBounds(F.Toolbar.Width - 96, 4, 88, 28);
  F.btnClose.Caption := 'Закрыть';
  F.btnClose.OnClick := @F.DoCloseBtn;

  F.Grid := TStringGrid.Create(F);
  F.Grid.Parent := F;
  F.Grid.Align := alClient;
  F.Grid.ColCount := 2;
  F.Grid.RowCount := 1;
  F.Grid.FixedCols := 0;
  F.Grid.FixedRows := 1;
  F.Grid.ColWidths[0] := 64;
  F.Grid.ColWidths[1] := 660;
  F.Grid.DefaultRowHeight := 22;
  F.Grid.AutoFillColumns := False;
  F.Grid.Options := [goVertLine, goHorzLine, goFixedHorzLine, goFixedVertLine,
    goEditing, goAlwaysShowEditor, goSmoothScroll, goColSizing];
  F.Grid.OnSelectEditor := @F.DoGridSelectEditor;
  F.Grid.OnEditingDone := @F.DoGridEditingDone;
  F.Grid.OnMouseDown := @F.DoGridMouseDown;
  F.Grid.OnPrepareCanvas := @F.DoGridPrepareCanvas;

  F.LoadFromFile;
  // After load: stretch the text column to fill width.
  F.Grid.ColWidths[1] := F.ClientWidth - F.Grid.ColWidths[0] - 24;

  F.ApplyShowTimes;
  F.UpdateCaption;
  GOpen.AddObject(Path, F);
  F.Show;
end;

finalization
  FreeAndNil(GOpen);
end.
