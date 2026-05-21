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
    btnToggleView: TButton;
    cbPeriod: TComboBox;
    cbTask: TComboBox;
    dtFrom: TDateEdit;
    dtTo: TDateEdit;
    lblFrom: TLabel;
    lblPeriod: TLabel;
    lblTask: TLabel;
    lblTo: TLabel;
    lblTotal: TLabel;
    lv: TListView;
    mmo: TMemo;
    pnlTop: TPanel;
    procedure btnCopyClick(Sender: TObject);
    procedure btnToggleViewClick(Sender: TObject);
    procedure cbPeriodChange(Sender: TObject);
    procedure cbTaskChange(Sender: TObject);
    procedure dtFromChange(Sender: TObject);
    procedure dtToChange(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FDataDir: string;
    FRows: array of TStatRow;
    FTotalMs: Int64;
    FByDay: Boolean;          // current view mode
    FInternalChange: Boolean; // suppress date/period OnChange recursion
    FFirstShow: Boolean;
    procedure ApplyPresetPeriod;
    procedure Refresh;
    procedure RebuildTaskList(const APreserveSelection: string);
    procedure CollectByTask(const ADate: TDateTime);
    procedure CollectByDay(const ADate: TDateTime; const ATask: string);
    function FindRow(const Key: string): Integer;
    procedure FillListView;
    procedure FillMemo;
    procedure SetColumnsByMode;
    function CurrentTask: string;
  public
    procedure ShowFor(const ADataDir: string);
  end;

var
  StatsForm: TStatsForm;

implementation

uses
  DOM, XMLRead, Clipbrd;

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
  FDataDir := ADataDir;
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
  end;
  ApplyPresetPeriod;
  Refresh;
end;

function TStatsForm.CurrentTask: string;
begin
  if (cbTask.ItemIndex <= 0) or (cbTask.Items[cbTask.ItemIndex] = CAllTasks) then
    Result := ''
  else
    Result := cbTask.Items[cbTask.ItemIndex];
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

procedure TStatsForm.cbTaskChange(Sender: TObject);
begin
  if FInternalChange then Exit;
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

procedure TStatsForm.RebuildTaskList(const APreserveSelection: string);
var
  Tasks: TStringList;
  D, EndD: TDateTime;
  Doc: TXMLDocument;
  Node: TDOMNode;
  F, N: string;
  Idx: Integer;
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
      F := DayFile(FDataDir, D);
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
                 and (Node.Attributes.GetNamedItem('task') <> nil) then
              begin
                N := Node.Attributes.GetNamedItem('task').NodeValue;
                if N <> '' then Tasks.Add(N);
              end;
              Node := Node.NextSibling;
            end;
          except
          end;
        finally
          Doc.Free;
        end;
      end;
      D := D + 1;
    end;

    FInternalChange := True;
    try
      cbTask.Items.BeginUpdate;
      try
        cbTask.Items.Clear;
        cbTask.Items.Add(CAllTasks);
        cbTask.Items.AddStrings(Tasks);
      finally
        cbTask.Items.EndUpdate;
      end;
      Idx := -1;
      if APreserveSelection <> '' then
        Idx := cbTask.Items.IndexOf(APreserveSelection);
      if Idx >= 0 then cbTask.ItemIndex := Idx
      else             cbTask.ItemIndex := 0;
    finally
      FInternalChange := False;
    end;
  finally
    Tasks.Free;
  end;
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

procedure TStatsForm.Refresh;
var
  StartD, EndD, D: TDateTime;
  i, j: Integer;
  Tmp: TStatRow;
  Task: string;
  CurrentSelection: string;
begin
  if (dtFrom.Date = 0) or (dtTo.Date = 0) then Exit;

  CurrentSelection := CurrentTask;
  if CurrentSelection = '' then CurrentSelection := CAllTasks;
  RebuildTaskList(CurrentSelection);

  Task := CurrentTask;
  FByDay := Task <> '';
  SetColumnsByMode;

  SetLength(FRows, 0);
  FTotalMs := 0;

  StartD := dtFrom.Date;
  EndD := dtTo.Date;
  if EndD < StartD then
  begin
    Tmp.SortKey := StartD; StartD := EndD; EndD := Tmp.SortKey; // swap
  end;

  D := StartD;
  while D <= EndD do
  begin
    if FByDay then CollectByDay(D, Task)
    else           CollectByTask(D);
    D := D + 1;
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
    if FByDay then
      Lines.Add('Задача: ' + CurrentTask);
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
