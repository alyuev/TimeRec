unit uaudiolist;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Grids, Graphics, LCLType, LMessages,
  Menus, Dialogs, Windows, ShellApi, laz2_XMLRead, laz2_XMLWrite, laz2_DOM;

type
  TRefRewriter = function(const OldName, NewName: string): Integer of object;

  TAudioListForm = class(TForm)
  private
    FGrid: TStringGrid;
    FAudioDir: string;
    FDataDir: string;
    FOriginalNames: TStringList;
    FOnHidden: TNotifyEvent;
    FPopup: TPopupMenu;
    FPendingPlayPath: string;
    FSortCol: Integer;
    FSortAsc: Boolean;
    procedure DoPlayPending(Data: PtrInt);
    procedure GridEditingDone(Sender: TObject);
    procedure GridSelectEditor(Sender: TObject; aCol, aRow: Integer;
      var Editor: TWinControl);
    procedure GridMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure GridHeaderClick(Sender: TObject; IsColumn: Boolean; Index: Integer);
    procedure GridKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormCloseQueryEv(Sender: TObject; var CanClose: Boolean);
    procedure MenuDeleteClick(Sender: TObject);
    procedure AddPopupItem(const ACaption: string; AHandler: TNotifyEvent);
    function RewriteRefs(const OldName, NewName: string): Integer;
    function RemoveRefs(const AName: string): Integer;
    procedure DoRename(Row: Integer; const NewName: string);
    function FormatSize(Bytes: Int64): string;
    procedure UpdateCaption;
    procedure UpdateHeaderArrows;
  public
    constructor CreateNew(AOwner: TComponent; Num: Integer = 0); override;
    destructor Destroy; override;
    procedure SetDirs(const AudioDir, DataDir: string);
    procedure RefreshList;
    procedure FocusFirstRowForTask(const TaskName: string);
    property OnHidden: TNotifyEvent read FOnHidden write FOnHidden;
  end;

implementation

constructor TAudioListForm.CreateNew(AOwner: TComponent; Num: Integer);
begin
  inherited CreateNew(AOwner, Num);
  BorderStyle := bsSizeToolWin;
  Caption := 'Записи аудио';
  Width := 820;
  Height := 280;
  ShowInTaskBar := stNever;
  KeyPreview := True;
  OnCloseQuery := @FormCloseQueryEv;
  FOriginalNames := TStringList.Create;
  FSortCol := 4;     // date column
  FSortAsc := False; // newest first

  FGrid := TStringGrid.Create(Self);
  FGrid.Parent := Self;
  FGrid.Align := alClient;
  FGrid.ColCount := 6;
  FGrid.RowCount := 1;
  FGrid.FixedCols := 0;
  FGrid.FixedRows := 1;
  FGrid.Cells[0, 0] := '▶';
  FGrid.Cells[1, 0] := 'Имя файла';
  FGrid.Cells[2, 0] := 'Длит.';
  FGrid.Cells[3, 0] := 'Размер';
  FGrid.Cells[4, 0] := 'Дата записи';
  FGrid.Cells[5, 0] := 'Задача';
  FGrid.ColWidths[0] := 28;
  FGrid.ColWidths[1] := 240;
  FGrid.ColWidths[2] := 60;
  FGrid.ColWidths[3] := 80;
  FGrid.ColWidths[4] := 140;
  FGrid.ColWidths[5] := 240;
  FGrid.Options := [goVertLine, goHorzLine, goFixedHorzLine, goFixedVertLine,
    goEditing, goRowSelect, goColSizing, goSmoothScroll];
  // Belt-and-suspenders: explicitly strip the options that, on some
  // LCL versions, cause hover to change the selected row and the grid
  // to snap back to the selected row when wheel-scrolling.
  FGrid.Options := FGrid.Options -
    [goRelaxedRowSelect, goScrollKeepVisible, goAlwaysShowEditor];
  FGrid.MouseWheelOption := mwGrid;
  FGrid.AutoFillColumns := False;
  FGrid.AutoAdvance := aaNone;
  FGrid.OnEditingDone := @GridEditingDone;
  FGrid.OnSelectEditor := @GridSelectEditor;
  FGrid.OnMouseDown := @GridMouseDown;
  FGrid.OnKeyDown := @GridKeyDown;
  FGrid.OnHeaderClick := @GridHeaderClick;

  FPopup := TPopupMenu.Create(Self);
  AddPopupItem('Удалить файл...', @MenuDeleteClick);
  FGrid.PopupMenu := FPopup;
end;

procedure TAudioListForm.AddPopupItem(const ACaption: string; AHandler: TNotifyEvent);
var
  Mi: TMenuItem;
begin
  Mi := TMenuItem.Create(FPopup);
  Mi.Caption := ACaption;
  Mi.OnClick := AHandler;
  FPopup.Items.Add(Mi);
end;

destructor TAudioListForm.Destroy;
begin
  FOriginalNames.Free;
  inherited;
end;

procedure TAudioListForm.FormCloseQueryEv(Sender: TObject; var CanClose: Boolean);
begin
  // Pressing the X just hides the window — main form keeps the
  // instance so user-set width/height persist for the next open.
  CanClose := False;
  Hide;
  if Assigned(FOnHidden) then FOnHidden(Self);
end;

procedure TAudioListForm.SetDirs(const AudioDir, DataDir: string);
begin
  FAudioDir := IncludeTrailingPathDelimiter(AudioDir);
  FDataDir  := IncludeTrailingPathDelimiter(DataDir);
  UpdateCaption;
end;

procedure TAudioListForm.UpdateCaption;
begin
  if FAudioDir <> '' then
    Caption := 'Записи аудио — ' + ExcludeTrailingPathDelimiter(FAudioDir)
  else
    Caption := 'Записи аудио';
end;

procedure TAudioListForm.UpdateHeaderArrows;
const
  HdrText: array[0..5] of string =
    ('▶', 'Имя файла', 'Длит.', 'Размер', 'Дата записи', 'Задача');
var
  i: Integer;
  Arrow: string;
begin
  for i := 0 to 5 do
  begin
    if (i = FSortCol) then
      if FSortAsc then Arrow := ' ↑' else Arrow := ' ↓'
    else
      Arrow := '';
    FGrid.Cells[i, 0] := HdrText[i] + Arrow;
  end;
end;

function TAudioListForm.FormatSize(Bytes: Int64): string;
begin
  if Bytes < 1024 then Result := IntToStr(Bytes) + ' B'
  else if Bytes < 1024 * 1024 then Result := Format('%.1f KB', [Bytes / 1024])
  else Result := Format('%.2f MB', [Bytes / (1024 * 1024)]);
end;

function GetMp3DurationSec(const Path: string): Double;
// Reads ID3v2 header (if any), then the first MPEG audio frame to get
// bitrate, then computes duration as (audio_bytes * 8 / bitrate).
// Exact for CBR (what our recorder produces).
const
  BrV1L3: array[0..14] of Integer =
    (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320);
  BrV2L3: array[0..14] of Integer =
    (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160);
var
  FS: TFileStream;
  Hdr: array[0..9] of Byte;
  Scan: array[0..2047] of Byte;
  ID3Size, AudioStart: Int64;
  i, N, Version, Layer, BitrateIdx, Bitrate: Integer;
begin
  Result := 0;
  if not FileExists(Path) then Exit;
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      AudioStart := 0;
      if FS.Read(Hdr, 10) = 10 then
        if (Hdr[0] = $49) and (Hdr[1] = $44) and (Hdr[2] = $33) then  // 'ID3'
        begin
          ID3Size := (Int64(Hdr[6]) shl 21) or (Int64(Hdr[7]) shl 14) or
                     (Int64(Hdr[8]) shl 7) or Int64(Hdr[9]);
          AudioStart := 10 + ID3Size;
        end;
      FS.Position := AudioStart;
      N := FS.Read(Scan, SizeOf(Scan));
      i := 0;
      while i < N - 3 do
      begin
        if (Scan[i] = $FF) and ((Scan[i + 1] and $E0) = $E0) then
        begin
          Version    := (Scan[i + 1] shr 3) and $3;
          Layer      := (Scan[i + 1] shr 1) and $3;
          BitrateIdx := (Scan[i + 2] shr 4) and $F;
          if (Layer = 1) and (BitrateIdx > 0) and (BitrateIdx < 15) then
          begin
            if Version = 3 then
              Bitrate := BrV1L3[BitrateIdx]   // MPEG1 Layer 3
            else if (Version = 2) or (Version = 0) then
              Bitrate := BrV2L3[BitrateIdx]   // MPEG2 / 2.5 Layer 3
            else
              Bitrate := 0;
            if Bitrate > 0 then
            begin
              Result := (FS.Size - AudioStart - i) * 8 / (Bitrate * 1000);
              Exit;
            end;
          end;
        end;
        Inc(i);
      end;
    finally
      FS.Free;
    end;
  except
  end;
end;

function FormatDur(Sec: Double): string;
var
  S, M, H: Integer;
begin
  if Sec <= 0 then Exit('—');
  S := Round(Sec);
  H := S div 3600;
  M := (S div 60) mod 60;
  S := S mod 60;
  if H > 0 then Result := Format('%d:%.2d:%.2d', [H, M, S])
  else          Result := Format('%d:%.2d', [M, S]);
end;

type
  TFileInfo = record
    Name: string;
    Size: Int64;
    Time: TDateTime;
    DurationSec: Double;
    Task: string;
  end;
  TFileInfoArr = array of TFileInfo;

procedure BuildTaskMap(const DataDir: string; Map: TStringList);
var
  SR: TSearchRec;
  Doc: TXMLDocument;
  Root, Entry, Aud: TDOMNode;
  TaskName, AudPath, AudKey: string;
begin
  Map.Clear;
  Map.CaseSensitive := False;
  if not DirectoryExists(DataDir) then Exit;
  if FindFirst(DataDir + '*.xml', faAnyFile and not faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Doc := nil;
      try
        try ReadXMLFile(Doc, DataDir + SR.Name) except Continue end;
        if Doc = nil then Continue;
        Root := Doc.DocumentElement;
        if Root = nil then Continue;
        Entry := Root.FirstChild;
        while Entry <> nil do
        begin
          if (Entry.NodeType = ELEMENT_NODE) then
          begin
            TaskName := TDOMElement(Entry).GetAttribute('task');
            Aud := Entry.FirstChild;
            while Aud <> nil do
            begin
              if (Aud.NodeType = ELEMENT_NODE) and (Aud.NodeName = 'audio') then
              begin
                AudPath := TDOMElement(Aud).GetAttribute('path');
                AudKey := ExtractFileName(AudPath);
                if (AudKey <> '') and (TaskName <> '') and
                   (Map.IndexOfName(AudKey) < 0) then
                  Map.Values[AudKey] := TaskName;
              end;
              Aud := Aud.NextSibling;
            end;
          end;
          Entry := Entry.NextSibling;
        end;
      finally
        Doc.Free;
      end;
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;

  // Fallback: pending-task tags written by the main form on Stop for
  // recordings whose segment hasn't been finalised yet. Day-xml
  // entries above take priority (we only fill the gaps).
  if FileExists(DataDir + 'audio_tasks.xml') then
  begin
    Doc := nil;
    try
      try ReadXMLFile(Doc, DataDir + 'audio_tasks.xml') except Doc := nil end;
      if Doc <> nil then
      begin
        Root := Doc.DocumentElement;
        if Root <> nil then
        begin
          Aud := Root.FirstChild;
          while Aud <> nil do
          begin
            if (Aud.NodeType = ELEMENT_NODE) and (Aud.NodeName = 'audio') then
            begin
              AudKey := TDOMElement(Aud).GetAttribute('path');
              TaskName := TDOMElement(Aud).GetAttribute('task');
              if (AudKey <> '') and (TaskName <> '') and
                 (Map.IndexOfName(AudKey) < 0) then
                Map.Values[AudKey] := TaskName;
            end;
            Aud := Aud.NextSibling;
          end;
        end;
      end;
    finally
      Doc.Free;
    end;
  end;
end;

function CompareFileInfo(const A, B: TFileInfo;
  SortCol: Integer; Asc: Boolean): Integer;
  // Returns negative / 0 / positive a-la strcmp.
  function NumDiff(x, y: Double): Integer;
  begin
    if x < y then Result := -1
    else if x > y then Result := 1
    else Result := 0;
  end;
begin
  case SortCol of
    1: Result := CompareText(A.Name, B.Name);
    2: Result := NumDiff(A.DurationSec, B.DurationSec);
    3: Result := NumDiff(A.Size, B.Size);
    5: Result := CompareText(A.Task, B.Task);
  else
    // default / col 4: by date
    Result := NumDiff(A.Time, B.Time);
  end;
  if not Asc then Result := -Result;
end;

procedure TAudioListForm.RefreshList;
var
  SR: TSearchRec;
  Items: TFileInfoArr;
  i, j: Integer;
  Tmp: TFileInfo;
  TaskMap: TStringList;
begin
  SetLength(Items, 0);
  if (FAudioDir = '') or (not DirectoryExists(FAudioDir)) then
  begin
    FGrid.RowCount := 1;
    UpdateHeaderArrows;
    Exit;
  end;
  TaskMap := TStringList.Create;
  try
    BuildTaskMap(FDataDir, TaskMap);
    if FindFirst(FAudioDir + '*.mp3', faAnyFile and not faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then
        begin
          SetLength(Items, Length(Items) + 1);
          Items[High(Items)].Name := SR.Name;
          Items[High(Items)].Size := SR.Size;
          Items[High(Items)].Time := FileDateToDateTime(LongInt(SR.Time));
          Items[High(Items)].DurationSec := GetMp3DurationSec(FAudioDir + SR.Name);
          Items[High(Items)].Task := TaskMap.Values[SR.Name];
        end;
      until FindNext(SR) <> 0;
    finally
      SysUtils.FindClose(SR);
    end;
  finally
    TaskMap.Free;
  end;

  // O(n²) sort — fine for typical recording counts.
  for i := 0 to High(Items) - 1 do
    for j := i + 1 to High(Items) do
      if CompareFileInfo(Items[i], Items[j], FSortCol, FSortAsc) > 0 then
      begin
        Tmp := Items[i]; Items[i] := Items[j]; Items[j] := Tmp;
      end;

  FGrid.RowCount := Length(Items) + 1;
  FOriginalNames.Clear;
  FOriginalNames.Add('');
  for i := 0 to High(Items) do
  begin
    FGrid.Cells[0, i + 1] := '▶';
    FGrid.Cells[1, i + 1] := Items[i].Name;
    FGrid.Cells[2, i + 1] := FormatDur(Items[i].DurationSec);
    FGrid.Cells[3, i + 1] := FormatSize(Items[i].Size);
    FGrid.Cells[4, i + 1] := FormatDateTime('yyyy-mm-dd hh:nn:ss', Items[i].Time);
    FGrid.Cells[5, i + 1] := Items[i].Task;
    FOriginalNames.Add(Items[i].Name);
  end;
  UpdateHeaderArrows;
end;

procedure TAudioListForm.GridHeaderClick(Sender: TObject; IsColumn: Boolean;
  Index: Integer);
var
  KeepName: string;
  i: Integer;
begin
  if not IsColumn then Exit;
  if Index = 0 then Exit;  // play column not sortable
  if Index = FSortCol then FSortAsc := not FSortAsc
  else
  begin
    FSortCol := Index;
    FSortAsc := True;
  end;
  // Remember which file the user had selected so we can restore the
  // cursor after the rows are reshuffled.
  KeepName := '';
  if (FGrid.Row >= 1) and (FGrid.Row < FGrid.RowCount) then
    KeepName := FGrid.Cells[1, FGrid.Row];
  RefreshList;
  if KeepName <> '' then
    for i := 1 to FGrid.RowCount - 1 do
      if FGrid.Cells[1, i] = KeepName then
      begin
        FGrid.Row := i;
        if FGrid.TopRow > i then FGrid.TopRow := i
        else if i >= FGrid.TopRow + FGrid.VisibleRowCount then
          FGrid.TopRow := i - FGrid.VisibleRowCount + 1;
        Break;
      end;
end;

procedure TAudioListForm.FocusFirstRowForTask(const TaskName: string);
var
  i: Integer;
  T: string;
begin
  if Trim(TaskName) = '' then Exit;
  T := LowerCase(Trim(TaskName));
  for i := 1 to FGrid.RowCount - 1 do
    if LowerCase(Trim(FGrid.Cells[5, i])) = T then
    begin
      FGrid.Row := i;
      // Ensure visible: scroll the grid so this row is in view.
      if FGrid.TopRow > i then FGrid.TopRow := i
      else if i >= FGrid.TopRow + FGrid.VisibleRowCount then
        FGrid.TopRow := i - FGrid.VisibleRowCount + 1;
      Exit;
    end;
end;

procedure TAudioListForm.GridSelectEditor(Sender: TObject; aCol, aRow: Integer;
  var Editor: TWinControl);
begin
  // Only column 1 (filename) is editable.
  if aCol <> 1 then Editor := nil;
end;

procedure TAudioListForm.GridMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Col, Row: Integer;
  Path: string;
begin
  FGrid.MouseToCell(X, Y, Col, Row);
  if (Button = mbRight) then
  begin
    if (Row >= 1) and (Row < FGrid.RowCount) then FGrid.Row := Row;
    Exit;
  end;
  if (Col = 0) and (Row >= 1) and (Row < FGrid.RowCount) then
  begin
    Path := FAudioDir + FGrid.Cells[1, Row];
    if FileExists(Path) then
    begin
      // Defer ShellExecute: launching an external player from inside
      // MouseDown swallows the matching MouseUp, leaving the grid
      // stuck in drag-select mode (rows track the cursor as it moves).
      FPendingPlayPath := Path;
      Application.QueueAsyncCall(@DoPlayPending, 0);
    end;
  end;
end;

procedure TAudioListForm.DoPlayPending(Data: PtrInt);
var
  P: string;
begin
  P := FPendingPlayPath;
  FPendingPlayPath := '';
  // Release any lingering capture state from the click that triggered us.
  if GetCapture <> 0 then ReleaseCapture;
  if P <> '' then
    ShellExecuteW(0, nil, PWideChar(UnicodeString(P)), nil, nil, 1);
end;

procedure TAudioListForm.GridKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  if (Key = VK_F2) and (FGrid.Row >= 1) then
  begin
    FGrid.Col := 1;
    FGrid.EditorMode := True;
    Key := 0;
  end;
end;

procedure TAudioListForm.GridEditingDone(Sender: TObject);
var
  Row: Integer;
  NewName: string;
begin
  Row := FGrid.Row;
  if (Row < 1) or (FGrid.Col <> 1) then Exit;
  NewName := Trim(FGrid.Cells[1, Row]);
  DoRename(Row, NewName);
end;

procedure TAudioListForm.DoRename(Row: Integer; const NewName: string);
var
  OldName, OldPath, NewPath, FinalName: string;
  UpdCount: Integer;
begin
  if (Row < 0) or (Row >= FOriginalNames.Count) then Exit;
  OldName := FOriginalNames[Row];
  if (NewName = '') or (NewName = OldName) then Exit;
  FinalName := NewName;
  if not SameText(ExtractFileExt(FinalName), '.mp3') then
    FinalName := FinalName + '.mp3';
  OldPath := FAudioDir + OldName;
  NewPath := FAudioDir + FinalName;
  if not FileExists(OldPath) then begin RefreshList; Exit; end;
  if FileExists(NewPath) and (not SameText(OldPath, NewPath)) then
  begin
    FGrid.Cells[1, Row] := OldName;  // revert
    Exit;
  end;
  if not RenameFile(OldPath, NewPath) then
  begin
    FGrid.Cells[1, Row] := OldName;
    Exit;
  end;
  UpdCount := RewriteRefs(OldName, FinalName);
  Caption := Format('Записи аудио — переименовано, ссылок обновлено: %d', [UpdCount]);
  RefreshList;
end;

procedure TAudioListForm.MenuDeleteClick(Sender: TObject);
var
  Row, Removed: Integer;
  FName, Path: string;
begin
  Row := FGrid.Row;
  if (Row < 1) or (Row >= FOriginalNames.Count) then Exit;
  FName := FOriginalNames[Row];
  Path := FAudioDir + FName;
  if MessageDlg('Удаление файла',
       Format('Удалить файл «%s» и убрать ссылки во всех заданиях?', [FName]),
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then Exit;
  if FileExists(Path) then
    if not SysUtils.DeleteFile(Path) then
    begin
      MessageDlg('Не удалось удалить файл (возможно, он сейчас используется).',
        mtError, [mbOK], 0);
      Exit;
    end;
  Removed := RemoveRefs(FName);
  Caption := Format('Записи аудио — удалено, ссылок убрано: %d', [Removed]);
  RefreshList;
end;

function TAudioListForm.RemoveRefs(const AName: string): Integer;
var
  SR: TSearchRec;
  Doc: TXMLDocument;
  Root, Entry, Aud, NextAud: TDOMNode;
  AttrPath: string;
  IsDirty: Boolean;
begin
  Result := 0;
  if not DirectoryExists(FDataDir) then Exit;
  if FindFirst(FDataDir + '*.xml', faAnyFile and not faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Doc := nil;
      try
        try ReadXMLFile(Doc, FDataDir + SR.Name) except Continue end;
        if Doc = nil then Continue;
        Root := Doc.DocumentElement;
        if Root = nil then Continue;
        IsDirty := False;
        Entry := Root.FirstChild;
        while Entry <> nil do
        begin
          Aud := Entry.FirstChild;
          while Aud <> nil do
          begin
            NextAud := Aud.NextSibling;
            if (Aud.NodeType = ELEMENT_NODE) and (Aud.NodeName = 'audio') then
            begin
              AttrPath := TDOMElement(Aud).GetAttribute('path');
              if (AttrPath = AName) or
                 SameText(ExtractFileName(AttrPath), AName) then
              begin
                Entry.RemoveChild(Aud);
                Inc(Result);
                IsDirty := True;
              end;
            end;
            Aud := NextAud;
          end;
          Entry := Entry.NextSibling;
        end;
        if IsDirty then WriteXMLFile(Doc, FDataDir + SR.Name);
      finally
        Doc.Free;
      end;
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

function TAudioListForm.RewriteRefs(const OldName, NewName: string): Integer;
var
  SR: TSearchRec;
  Doc: TXMLDocument;
  Root, Entry, Aud: TDOMNode;
  AttrPath: string;
  IsDirty: Boolean;
begin
  Result := 0;
  if not DirectoryExists(FDataDir) then Exit;
  if FindFirst(FDataDir + '*.xml', faAnyFile and not faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Doc := nil;
      try
        try ReadXMLFile(Doc, FDataDir + SR.Name) except Continue end;
        if Doc = nil then Continue;
        Root := Doc.DocumentElement;
        if Root = nil then Continue;
        IsDirty := False;
        Entry := Root.FirstChild;
        while Entry <> nil do
        begin
          Aud := Entry.FirstChild;
          while Aud <> nil do
          begin
            if (Aud.NodeType = ELEMENT_NODE) and (Aud.NodeName = 'audio') then
            begin
              AttrPath := TDOMElement(Aud).GetAttribute('path');
              if (AttrPath = OldName) or
                 SameText(ExtractFileName(AttrPath), OldName) then
              begin
                if Pos(PathDelim, AttrPath) > 0 then
                  TDOMElement(Aud).SetAttribute('path',
                    ExtractFilePath(AttrPath) + NewName)
                else
                  TDOMElement(Aud).SetAttribute('path', NewName);
                Inc(Result);
                IsDirty := True;
              end;
            end;
            Aud := Aud.NextSibling;
          end;
          Entry := Entry.NextSibling;
        end;
        if IsDirty then WriteXMLFile(Doc, FDataDir + SR.Name);
      finally
        Doc.Free;
      end;
    until FindNext(SR) <> 0;
  finally
    SysUtils.FindClose(SR);
  end;
end;

end.
