unit ustats;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, ComCtrls,
  EditBtn, DateUtils;

type
  TStatRow = record
    Key: string;        // task name (by-task mode) or 'dd.mm.yyyy' (by-day mode)
    DurationMs: Int64;
    Sessions: Integer;
    SortKey: TDateTime; // first-start (by-task) or the day itself (by-day)
  end;

  TStatsForm = class(TForm)
    btnCopy: TButton;
    btnKind: TButton;
    btnKindReset: TButton;
    btnTask: TButton;
    btnTaskReset: TButton;
    btnToggleView: TButton;
    cbPeriod: TComboBox;
    chkKindExclude: TCheckBox;
    dtFrom: TDateEdit;
    dtTo: TDateEdit;
    lblFrom: TLabel;
    lblKind: TLabel;
    lblPeriod: TLabel;
    lblTask: TLabel;
    lblTo: TLabel;
    lblTotal: TLabel;
    lv: TListView;
    mmo: TMemo;
    pnlTop: TPanel;
    procedure btnCopyClick(Sender: TObject);
    procedure btnKindClick(Sender: TObject);
    procedure btnKindResetClick(Sender: TObject);
    procedure btnTaskClick(Sender: TObject);
    procedure btnTaskResetClick(Sender: TObject);
    procedure btnToggleViewClick(Sender: TObject);
    procedure cbPeriodChange(Sender: TObject);
    procedure chkKindExcludeChange(Sender: TObject);
    procedure dtFromChange(Sender: TObject);
    procedure dtToChange(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FDataDir: string;
    FLazyCureDir: string;
    FRows: array of TStatRow;
    FTotalMs: Int64;
    FByDay: Boolean;          // current view mode
    FInternalChange: Boolean; // suppress date/period OnChange recursion
    FFirstShow: Boolean;
    FSelectedTasks: TStringList;
    FAllTasks: TStringList;
    FSelectedKinds: TStringList;
    FAllKinds: TStringList;
    FTaskKinds: TStringList;  // name=kind map from tasks.xml
    FTasksFile: string;
    procedure ApplyPresetPeriod;
    procedure Refresh;
    procedure RebuildTaskList;
    procedure UpdateTaskButtons;
    procedure UpdateKindButtons;
    procedure LoadKindsMap;
    function TaskKind(const Task: string): string;
    function KindFilterAllows(const Task: string): Boolean;
    procedure CollectByTask(const ADate: TDateTime);
    procedure CollectByDay(const ADate: TDateTime; const ATask: string);
    procedure CollectLazyCure(const ADate: TDateTime; const ATask: string;
      ByDay: Boolean);
    function FindRow(const Key: string): Integer;
    procedure FillListView;
    procedure FillMemo;
    procedure SetColumnsByMode;
    function TaskFilterCaption: string;
  public
    procedure ShowFor(const ADataDir: string); overload;
    procedure ShowFor(const ADataDir, ALazyCureDir: string); overload;
    procedure ShowFor(const ADataDir, ALazyCureDir, ATasksFile: string); overload;
  end;

var
  StatsForm: TStatsForm;

implementation

uses
  DOM, XMLRead, Clipbrd, utaskpick;

{$R *.lfm}

const
  CAllTasks = '(все)';

function FormatHHMMSS(MsTotal: Int64): string;
var H, M, S: Int64;
begin
  S := MsTotal div 1000;
  H := S div 3600;
  M := (S mod 3600) div 60;
  S := S mod 60;
  Result := Format('%.2d:%.2d:%.2d', [H, M, S]);
end;

function FormatHMin(MsTotal: Int64): string;
var TotalMin, H, M: Int64;
begin
  TotalMin := MsTotal div 60000;
  if TotalMin = 0 then Exit('<1мин');
  H := TotalMin div 60;
  M := TotalMin mod 60;
  if H = 0 then      Result := IntToStr(M) + 'мин'
  else if M = 0 then Result := IntToStr(H) + 'ч'
  else               Result := IntToStr(H) + 'ч' + IntToStr(M) + 'мин';
end;

function DayFile(const Dir: string; D: TDateTime): string;
begin
  Result := Dir + PathDelim + FormatDateTime('yyyy-mm-dd', D) + '.xml';
end;

function LazyCureFile(const LCDir: string; D: TDateTime): string;
begin
  if LCDir = '' then Exit('');
  Result := LCDir + PathDelim + FormatDateTime('yyyy-mm-dd', D) + '.timelog';
end;

function ParseHMS(const S: string; out Seconds: Int64): Boolean;
var
  P1, P2: Integer;
  H, M, Sec: Integer;
begin
  Result := False;
  P1 := Pos(':', S);
  if P1 = 0 then Exit;
  P2 := Pos(':', S, P1 + 1);
  if P2 = 0 then Exit;
  if not TryStrToInt(Copy(S, 1, P1 - 1), H) then Exit;
  if not TryStrToInt(Copy(S, P1 + 1, P2 - P1 - 1), M) then Exit;
  if not TryStrToInt(Copy(S, P2 + 1, MaxInt), Sec) then Exit;
  Seconds := Int64(H) * 3600 + M * 60 + Sec;
  Result := True;
end;

function ParseHMSTime(const S: string; out T: TDateTime): Boolean;
var
  Secs: Int64;
begin
  Result := ParseHMS(S, Secs);
  if Result then T := Secs / 86400.0;
end;

function ParseIsoLite(const S: string; out DT: TDateTime): Boolean;
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
    DT := EncodeDateTime(Y, Mo, D, H, Mi, Se, 0);
    Result := True;
  except
  end;
end;

procedure TStatsForm.ShowFor(const ADataDir: string);
begin
  ShowFor(ADataDir, ADataDir + PathDelim + 'LazyCure', '');
end;

procedure TStatsForm.ShowFor(const ADataDir, ALazyCureDir: string);
begin
  ShowFor(ADataDir, ALazyCureDir, '');
end;

procedure TStatsForm.ShowFor(const ADataDir, ALazyCureDir, ATasksFile: string);
begin
  FDataDir := ADataDir;
  FLazyCureDir := ALazyCureDir;
  FTasksFile := ATasksFile;
  FFirstShow := True;
  Show;
  BringToFront;
end;

procedure TStatsForm.FormShow(Sender: TObject);
begin
  if FFirstShow then
  begin
    FFirstShow := False;
    FInternalChange := True;
    try
      dtFrom.Date := Date;
      dtTo.Date := Date;
    finally
      FInternalChange := False;
    end;
    if FSelectedTasks = nil then FSelectedTasks := TStringList.Create;
    if FAllTasks      = nil then FAllTasks      := TStringList.Create;
    if FSelectedKinds = nil then FSelectedKinds := TStringList.Create;
    if FAllKinds      = nil then FAllKinds      := TStringList.Create;
    if FTaskKinds     = nil then begin
      FTaskKinds := TStringList.Create;
      FTaskKinds.CaseSensitive := True;
    end;
  end;
  ApplyPresetPeriod;
  Refresh;
end;

function TStatsForm.TaskFilterCaption: string;
begin
  if (FSelectedTasks = nil) or (FSelectedTasks.Count = 0) then
    Result := 'Все задачи'
  else if FSelectedTasks.Count = 1 then
    Result := FSelectedTasks[0]
  else
    Result := Format('Выбрано: %d', [FSelectedTasks.Count]);
end;

procedure TStatsForm.UpdateTaskButtons;
begin
  btnTask.Caption := TaskFilterCaption;
  btnTaskReset.Enabled := (FSelectedTasks <> nil) and (FSelectedTasks.Count > 0);
end;

procedure TStatsForm.btnTaskClick(Sender: TObject);
var
  Sel: TStringList;
begin
  Sel := TStringList.Create;
  try
    if PickTasks(Self, FAllTasks, FSelectedTasks, Sel) then
    begin
      FSelectedTasks.Assign(Sel);
      UpdateTaskButtons;
      Refresh;
    end;
  finally
    Sel.Free;
  end;
end;

procedure TStatsForm.btnTaskResetClick(Sender: TObject);
begin
  if FSelectedTasks <> nil then FSelectedTasks.Clear;
  UpdateTaskButtons;
  Refresh;
end;

procedure TStatsForm.btnKindClick(Sender: TObject);
var
  Sel: TStringList;
begin
  Sel := TStringList.Create;
  try
    if PickTasks(Self, FAllKinds, FSelectedKinds, Sel) then
    begin
      FSelectedKinds.Assign(Sel);
      UpdateKindButtons;
      Refresh;
    end;
  finally
    Sel.Free;
  end;
end;

procedure TStatsForm.btnKindResetClick(Sender: TObject);
begin
  if FSelectedKinds <> nil then FSelectedKinds.Clear;
  chkKindExclude.Checked := False;
  UpdateKindButtons;
  Refresh;
end;

procedure TStatsForm.chkKindExcludeChange(Sender: TObject);
begin
  if FInternalChange then Exit;
  Refresh;
end;

procedure TStatsForm.UpdateKindButtons;
var
  S: string;
begin
  if (FSelectedKinds = nil) or (FSelectedKinds.Count = 0) then
    S := 'Все виды'
  else if FSelectedKinds.Count = 1 then
    S := FSelectedKinds[0]
  else
    S := Format('Выбрано: %d', [FSelectedKinds.Count]);
  btnKind.Caption := S;
  btnKindReset.Enabled := (FSelectedKinds <> nil) and (FSelectedKinds.Count > 0);
end;

procedure TStatsForm.LoadKindsMap;
var
  Doc: TXMLDocument;
  Node: TDOMNode;
  TaskNm, Kind: string;
  i: Integer;
begin
  FTaskKinds.Clear;
  FAllKinds.Clear;
  if (FTasksFile = '') or (not FileExists(FTasksFile)) then Exit;
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
          TaskNm := Node.Attributes.GetNamedItem('name').NodeValue;
          if Node.Attributes.GetNamedItem('kind') <> nil then
            Kind := Node.Attributes.GetNamedItem('kind').NodeValue
          else
            Kind := '';
          if TaskNm <> '' then
            FTaskKinds.Values[TaskNm] := Kind;
          if (Kind <> '') and (FAllKinds.IndexOf(Kind) < 0) then
            FAllKinds.Add(Kind);
        end;
        Node := Node.NextSibling;
      end;
    except
    end;
  finally
    Doc.Free;
  end;
  FAllKinds.Sort;
  if FSelectedKinds <> nil then
    for i := FSelectedKinds.Count - 1 downto 0 do
      if FAllKinds.IndexOf(FSelectedKinds[i]) < 0 then
        FSelectedKinds.Delete(i);
end;

function TStatsForm.TaskKind(const Task: string): string;
begin
  if FTaskKinds = nil then Exit('');
  Result := FTaskKinds.Values[Task];
end;

function TStatsForm.KindFilterAllows(const Task: string): Boolean;
var
  K: string;
  InSet: Boolean;
begin
  Result := True;
  if (FSelectedKinds = nil) or (FSelectedKinds.Count = 0) then Exit;
  K := TaskKind(Task);
  InSet := FSelectedKinds.IndexOf(K) >= 0;
  if chkKindExclude.Checked then
    Result := not InSet
  else
    Result := InSet;
end;

procedure TStatsForm.ApplyPresetPeriod;
var
  ED: TDateTime;
begin
  // Translate the preset into dtFrom/dtTo. "Произвольный" leaves them as-is.
  ED := Date;
  FInternalChange := True;
  try
    case cbPeriod.ItemIndex of
      0: begin dtFrom.Date := ED;                    dtTo.Date := ED;     end;
      1: begin dtFrom.Date := ED - 1;                dtTo.Date := ED - 1; end;
      2: begin dtFrom.Date := ED - 6;                dtTo.Date := ED;     end;
      3: begin dtFrom.Date := IncMonth(ED, -1) + 1;  dtTo.Date := ED;     end;
      4: begin // Произвольный — keep current dates, ensure non-zero
           if dtFrom.Date = 0 then dtFrom.Date := ED;
           if dtTo.Date   = 0 then dtTo.Date   := ED;
         end;
    end;
  finally
    FInternalChange := False;
  end;
end;

procedure TStatsForm.cbPeriodChange(Sender: TObject);
begin
  if FInternalChange then Exit;
  ApplyPresetPeriod;
  Refresh;
end;

procedure TStatsForm.dtFromChange(Sender: TObject);
begin
  if FInternalChange then Exit;
  FInternalChange := True;
  try
    cbPeriod.ItemIndex := 4; // Произвольный
  finally
    FInternalChange := False;
  end;
  Refresh;
end;

procedure TStatsForm.dtToChange(Sender: TObject);
begin
  if FInternalChange then Exit;
  FInternalChange := True;
  try
    cbPeriod.ItemIndex := 4;
  finally
    FInternalChange := False;
  end;
  Refresh;
end;

procedure TStatsForm.btnToggleViewClick(Sender: TObject);
begin
  if mmo.Visible then
  begin
    mmo.Visible := False;
    lv.Visible := True;
    btnToggleView.Caption := 'Текстом';
    btnCopy.Visible := False;
  end
  else
  begin
    FillMemo;
    lv.Visible := False;
    mmo.Visible := True;
    btnToggleView.Caption := 'Таблицей';
    btnCopy.Visible := True;
  end;
end;

procedure TStatsForm.btnCopyClick(Sender: TObject);
begin
  Clipboard.AsText := mmo.Text;
end;

function TStatsForm.FindRow(const Key: string): Integer;
var i: Integer;
begin
  for i := 0 to High(FRows) do
    if FRows[i].Key = Key then Exit(i);
  Result := -1;
end;

procedure TStatsForm.CollectByTask(const ADate: TDateTime);
var
  Doc: TXMLDocument;
  Node: TDOMNode;
  TaskName, DurStr: string;
  StartDT: TDateTime;
  AddMs: Int64;
  Idx: Integer;
  F: string;
begin
  F := DayFile(FDataDir, ADate);
  if not FileExists(F) then Exit;
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
          TaskName := Node.Attributes.GetNamedItem('task').NodeValue;
          DurStr := Node.Attributes.GetNamedItem('durationMs').NodeValue;
          AddMs := StrToInt64Def(DurStr, 0);
          StartDT := 0;
          if Node.Attributes.GetNamedItem('start') <> nil then
            ParseIsoLite(Node.Attributes.GetNamedItem('start').NodeValue, StartDT);
          Idx := FindRow(TaskName);
          if Idx < 0 then
          begin
            SetLength(FRows, Length(FRows) + 1);
            with FRows[High(FRows)] do
            begin
              Key := TaskName;
              DurationMs := AddMs;
              Sessions := 1;
              SortKey := StartDT;
            end;
          end
          else
          begin
            Inc(FRows[Idx].DurationMs, AddMs);
            Inc(FRows[Idx].Sessions);
            if (StartDT <> 0) and ((FRows[Idx].SortKey = 0)
                or (StartDT < FRows[Idx].SortKey)) then
              FRows[Idx].SortKey := StartDT;
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

procedure TStatsForm.CollectByDay(const ADate: TDateTime; const ATask: string);
var
  Doc: TXMLDocument;
  Node: TDOMNode;
  TaskName, DurStr, DayKey: string;
  AddMs: Int64;
  Idx: Integer;
  F: string;
begin
  F := DayFile(FDataDir, ADate);
  if not FileExists(F) then Exit;
  Doc := nil;
  DayKey := FormatDateTime('dd.mm.yyyy', ADate);
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
          TaskName := Node.Attributes.GetNamedItem('task').NodeValue;
          if TaskName = ATask then
          begin
            DurStr := Node.Attributes.GetNamedItem('durationMs').NodeValue;
            AddMs := StrToInt64Def(DurStr, 0);
            Idx := FindRow(DayKey);
            if Idx < 0 then
            begin
              SetLength(FRows, Length(FRows) + 1);
              with FRows[High(FRows)] do
              begin
                Key := DayKey;
                DurationMs := AddMs;
                Sessions := 1;
                SortKey := ADate;
              end;
            end
            else
            begin
              Inc(FRows[Idx].DurationMs, AddMs);
              Inc(FRows[Idx].Sessions);
            end;
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

procedure TStatsForm.RebuildTaskList;
var
  Tasks: TStringList;
  D, EndD: TDateTime;
  Doc: TXMLDocument;
  Node: TDOMNode;
  F, N: string;
  i: Integer;

  procedure ScanFile(const Path, EntryTag, NameAttr: string);
  var
    Child: TDOMNode;
  begin
    if not FileExists(Path) then Exit;
    Doc := nil;
    try
      try
        ReadXMLFile(Doc, Path);
        Node := Doc.DocumentElement.FirstChild;
        while Node <> nil do
        begin
          if Node.NodeName = EntryTag then
          begin
            if (NameAttr = 'task') and (Node.Attributes <> nil)
               and (Node.Attributes.GetNamedItem('task') <> nil) then
            begin
              N := Node.Attributes.GetNamedItem('task').NodeValue;
              if N <> '' then Tasks.Add(N);
            end
            else if NameAttr = 'Activity' then
            begin
              Child := Node.FirstChild;
              while Child <> nil do
              begin
                if Child.NodeName = 'Activity' then
                begin
                  if Child.FirstChild <> nil then
                    N := Child.FirstChild.NodeValue
                  else
                    N := '';
                  if N <> '' then Tasks.Add(N);
                  Break;
                end;
                Child := Child.NextSibling;
              end;
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

begin
  Tasks := TStringList.Create;
  try
    Tasks.Sorted := True;
    Tasks.Duplicates := dupIgnore;
    D := dtFrom.Date;
    EndD := dtTo.Date;
    if (D = 0) or (EndD = 0) then Exit;
    while D <= EndD do
    begin
      ScanFile(DayFile(FDataDir, D),     'entry',   'task');
      ScanFile(LazyCureFile(FLazyCureDir,D), 'Records', 'Activity');
      D := D + 1;
    end;

    FAllTasks.Assign(Tasks);
    for i := FSelectedTasks.Count - 1 downto 0 do
      if FAllTasks.IndexOf(FSelectedTasks[i]) < 0 then
        FSelectedTasks.Delete(i);
  finally
    Tasks.Free;
  end;
  UpdateTaskButtons;
end;

procedure TStatsForm.SetColumnsByMode;
begin
  if FByDay then
  begin
    lv.Columns[0].Caption := 'Дата';
    lv.Columns[1].Caption := 'Длительность';
    lv.Columns[2].Caption := 'Сеансов';
  end
  else
  begin
    lv.Columns[0].Caption := 'Задача';
    lv.Columns[1].Caption := 'Длительность';
    lv.Columns[2].Caption := 'Сеансов';
  end;
end;

procedure TStatsForm.CollectLazyCure(const ADate: TDateTime;
  const ATask: string; ByDay: Boolean);
var
  Doc: TXMLDocument;
  Node, Child: TDOMNode;
  TaskName, StartS, DurS, DayKey: string;
  StartT: TDateTime;
  StartDT: TDateTime;
  DurSec: Int64;
  AddMs: Int64;
  Idx: Integer;
  F: string;
begin
  F := LazyCureFile(FLazyCureDir,ADate);
  if not FileExists(F) then Exit;
  Doc := nil;
  DayKey := FormatDateTime('dd.mm.yyyy', ADate);
  try
    try
      ReadXMLFile(Doc, F);
      Node := Doc.DocumentElement.FirstChild;
      while Node <> nil do
      begin
        if Node.NodeName = 'Records' then
        begin
          TaskName := ''; StartS := ''; DurS := '';
          Child := Node.FirstChild;
          while Child <> nil do
          begin
            if (Child.NodeName = 'Activity') and (Child.FirstChild <> nil) then
              TaskName := Child.FirstChild.NodeValue
            else if (Child.NodeName = 'Start') and (Child.FirstChild <> nil) then
              StartS := Child.FirstChild.NodeValue
            else if (Child.NodeName = 'Duration') and (Child.FirstChild <> nil) then
              DurS := Child.FirstChild.NodeValue;
            Child := Child.NextSibling;
          end;
          if (TaskName <> '') and ParseHMSTime(StartS, StartT)
             and ParseHMS(DurS, DurSec) then
          begin
            StartDT := Trunc(ADate) + StartT;
            AddMs := DurSec * 1000;
            if ByDay then
            begin
              if TaskName = ATask then
              begin
                Idx := FindRow(DayKey);
                if Idx < 0 then
                begin
                  SetLength(FRows, Length(FRows) + 1);
                  with FRows[High(FRows)] do
                  begin
                    Key := DayKey;
                    DurationMs := AddMs;
                    Sessions := 1;
                    SortKey := ADate;
                  end;
                end
                else
                begin
                  Inc(FRows[Idx].DurationMs, AddMs);
                  Inc(FRows[Idx].Sessions);
                end;
              end;
            end
            else
            begin
              Idx := FindRow(TaskName);
              if Idx < 0 then
              begin
                SetLength(FRows, Length(FRows) + 1);
                with FRows[High(FRows)] do
                begin
                  Key := TaskName;
                  DurationMs := AddMs;
                  Sessions := 1;
                  SortKey := StartDT;
                end;
              end
              else
              begin
                Inc(FRows[Idx].DurationMs, AddMs);
                Inc(FRows[Idx].Sessions);
                if (FRows[Idx].SortKey = 0) or (StartDT < FRows[Idx].SortKey) then
                  FRows[Idx].SortKey := StartDT;
              end;
            end;
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

procedure TStatsForm.Refresh;
var
  StartD, EndD, D: TDateTime;
  i, j, k: Integer;
  Tmp: TStatRow;
  Task: string;
  KeepIdx: array of Integer;
begin
  if (dtFrom.Date = 0) or (dtTo.Date = 0) then Exit;
  if FSelectedTasks = nil then FSelectedTasks := TStringList.Create;
  if FAllTasks      = nil then FAllTasks      := TStringList.Create;
  if FSelectedKinds = nil then FSelectedKinds := TStringList.Create;
  if FAllKinds      = nil then FAllKinds      := TStringList.Create;
  if FTaskKinds     = nil then begin
    FTaskKinds := TStringList.Create; FTaskKinds.CaseSensitive := True;
  end;

  LoadKindsMap;
  UpdateKindButtons;
  RebuildTaskList;

  // Mode: 1 task selected → by-day; else (0 or 2+) → by-task
  FByDay := FSelectedTasks.Count = 1;
  if FByDay then Task := FSelectedTasks[0] else Task := '';
  SetColumnsByMode;

  SetLength(FRows, 0);
  FTotalMs := 0;

  StartD := dtFrom.Date;
  EndD := dtTo.Date;
  if EndD < StartD then
  begin
    Tmp.SortKey := StartD; StartD := EndD; EndD := Tmp.SortKey;
  end;

  D := StartD;
  while D <= EndD do
  begin
    if FByDay then CollectByDay(D, Task)
    else           CollectByTask(D);
    CollectLazyCure(D, Task, FByDay);
    D := D + 1;
  end;

  // When 2+ tasks selected (in by-task mode), filter the per-task rows.
  // Also apply kind filter (only meaningful in by-task mode where Key=task).
  if not FByDay then
  begin
    SetLength(KeepIdx, 0);
    for i := 0 to High(FRows) do
    begin
      if (FSelectedTasks.Count > 0) and (FSelectedTasks.IndexOf(FRows[i].Key) < 0) then
        Continue;
      if not KindFilterAllows(FRows[i].Key) then Continue;
      SetLength(KeepIdx, Length(KeepIdx) + 1);
      KeepIdx[High(KeepIdx)] := i;
    end;
    if Length(KeepIdx) < Length(FRows) then
    begin
      k := 0;
      for i := 0 to High(KeepIdx) do
      begin
        if KeepIdx[i] <> k then FRows[k] := FRows[KeepIdx[i]];
        Inc(k);
      end;
      SetLength(FRows, k);
    end;
  end;

  for i := 0 to High(FRows) - 1 do
    for j := i + 1 to High(FRows) do
      if FRows[j].SortKey < FRows[i].SortKey then
      begin
        Tmp := FRows[i];
        FRows[i] := FRows[j];
        FRows[j] := Tmp;
      end;

  for i := 0 to High(FRows) do
    Inc(FTotalMs, FRows[i].DurationMs);

  lblTotal.Caption := 'Итого: ' + FormatHHMMSS(FTotalMs)
                    + '  (' + FormatHMin(FTotalMs) + ')';

  if mmo.Visible then FillMemo
  else                FillListView;
end;

procedure TStatsForm.FillListView;
var
  i: Integer;
  Item: TListItem;
begin
  lv.Items.BeginUpdate;
  try
    lv.Items.Clear;
    for i := 0 to High(FRows) do
    begin
      Item := lv.Items.Add;
      Item.Caption := FRows[i].Key;
      Item.SubItems.Add(FormatHMin(FRows[i].DurationMs));
      Item.SubItems.Add(IntToStr(FRows[i].Sessions));
    end;
  finally
    lv.Items.EndUpdate;
  end;
end;

procedure TStatsForm.FillMemo;
var
  i, MaxLen: Integer;
  S, DurS, PeriodStr: string;
  Lines: TStringList;
begin
  Lines := TStringList.Create;
  try
    if dtFrom.Date = dtTo.Date then
      PeriodStr := FormatDateTime('dd.mm.yyyy', dtFrom.Date)
    else
      PeriodStr := FormatDateTime('dd.mm.yyyy', dtFrom.Date) + ' — '
                 + FormatDateTime('dd.mm.yyyy', dtTo.Date);

    Lines.Add('Период: ' + PeriodStr);
    if FSelectedTasks.Count > 0 then
      Lines.Add('Задачи: ' + FSelectedTasks.CommaText);
    Lines.Add('Итого:  ' + FormatHMin(FTotalMs)
              + '  (' + FormatHHMMSS(FTotalMs) + ')');
    Lines.Add(StringOfChar('-', 60));

    MaxLen := 0;
    for i := 0 to High(FRows) do
    begin
      DurS := FormatHMin(FRows[i].DurationMs);
      if Length(DurS) > MaxLen then MaxLen := Length(DurS);
    end;

    for i := 0 to High(FRows) do
    begin
      DurS := FormatHMin(FRows[i].DurationMs);
      S := DurS + StringOfChar(' ', MaxLen - Length(DurS) + 2)
           + '— ' + FRows[i].Key;
      Lines.Add(S);
    end;
    mmo.Lines.Assign(Lines);
  finally
    Lines.Free;
  end;
end;

end.
