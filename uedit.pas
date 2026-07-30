unit uedit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Grids, Dialogs,
  LazUTF8;

type
  TEditForm = class(TForm)
    btnAdd: TButton;
    btnDel: TButton;
    btnReload: TButton;
    btnSave: TButton;
    cbFile: TComboBox;
    lblFile: TLabel;
    pnlTop: TPanel;
    sg: TStringGrid;
    procedure btnAddClick(Sender: TObject);
    procedure btnDelClick(Sender: TObject);
    procedure btnReloadClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure SyncTasksXmlFromGrid;
    procedure cbFileChange(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure sgEditingDone(Sender: TObject);
  private
    FDataDir: string;
    procedure RefreshFileList;
    procedure LoadCurrentFile;
    function CurrentFilePath: string;
    procedure SetupHeaders;
    procedure RecalcRow(R: Integer; Silent: Boolean);
  public
    procedure ShowFor(const ADataDir: string);
  end;

var
  EditForm: TEditForm;

implementation

uses
  DOM, XMLRead, XMLWrite, DateUtils;

{$R *.lfm}

const
  IsoFmt  = 'yyyy"-"mm"-"dd"T"hh":"nn":"ss';
  TimeFmt = 'hh:nn:ss';

procedure UpsertTaskName(const TasksFile, TaskName: string);
// Add or refresh a task entry in data/tasks.xml. If a case-insensitive
// match already exists, its «name» is updated to the new casing so the
// dropdown reflects the version the user just typed.
var
  Doc: TXMLDocument;
  Root: TDOMElement;
  Node: TDOMNode;
  Cur, LowerNew: string;
  Found: Boolean;
begin
  if Trim(TaskName) = '' then Exit;
  LowerNew := UTF8LowerCase(TaskName);
  Doc := nil;
  Found := False;
  try
    if FileExists(TasksFile) then
    begin
      ReadXMLFile(Doc, TasksFile);
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
         and (Node.Attributes.GetNamedItem('name') <> nil) then
      begin
        Cur := Node.Attributes.GetNamedItem('name').NodeValue;
        if UTF8LowerCase(Cur) = LowerNew then
        begin
          if Cur <> TaskName then
            TDOMElement(Node).SetAttribute('name', TaskName);
          Found := True;
          Break;
        end;
      end;
      Node := Node.NextSibling;
    end;
    if not Found then
    begin
      Node := Doc.CreateElement('task');
      TDOMElement(Node).SetAttribute('name', TaskName);
      Root.AppendChild(Node);
    end;
    WriteXMLFile(Doc, TasksFile);
  finally
    Doc.Free;
  end;
end;

function ParseIso(const S: string; out DT: TDateTime): Boolean;
var
  Y, Mo, D, H, Mi, Se: Integer;
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
    Result := False;
  end;
end;

procedure TEditForm.ShowFor(const ADataDir: string);
begin
  FDataDir := ADataDir;
  Show;
  BringToFront;
end;

procedure TEditForm.SetupHeaders;
begin
  sg.ColCount := 4;
  sg.FixedRows := 1;
  sg.Cells[0, 0] := 'Задача';
  sg.Cells[1, 0] := 'Начало';
  sg.Cells[2, 0] := 'Окончание';
  sg.Cells[3, 0] := 'Длительность';
end;

procedure TEditForm.FormShow(Sender: TObject);
begin
  SetupHeaders;
  RefreshFileList;
end;

procedure TEditForm.RefreshFileList;
var
  Sr: TSearchRec;
  Today: string;
  Idx: Integer;
  Names: TStringList;
  i: Integer;
begin
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    if FindFirst(FDataDir + PathDelim + '*.xml', faAnyFile, Sr) = 0 then
    begin
      repeat
        if (Sr.Name <> 'tasks.xml') and (Sr.Name <> 'current.xml')
           and (Sr.Name <> '.') and (Sr.Name <> '..') then
          Names.Add(ChangeFileExt(Sr.Name, ''));
      until FindNext(Sr) <> 0;
      FindClose(Sr);
    end;
    cbFile.Items.BeginUpdate;
    try
      cbFile.Items.Clear;
      // Names is ascending (yyyy-mm-dd) — feed in reverse so newest is on top
      for i := Names.Count - 1 downto 0 do
        cbFile.Items.Add(Names[i]);
    finally
      cbFile.Items.EndUpdate;
    end;
  finally
    Names.Free;
  end;
  Today := FormatDateTime('yyyy-mm-dd', Now);
  Idx := cbFile.Items.IndexOf(Today);
  // List is sorted newest-first; fall back to the top entry (most recent)
  if (Idx < 0) and (cbFile.Items.Count > 0) then
    Idx := 0;
  if Idx >= 0 then
  begin
    cbFile.ItemIndex := Idx;
    LoadCurrentFile;
  end
  else
  begin
    sg.RowCount := 1;
    SetupHeaders;
  end;
end;

function TEditForm.CurrentFilePath: string;
begin
  if cbFile.ItemIndex < 0 then
    Result := ''
  else
    Result := FDataDir + PathDelim + cbFile.Items[cbFile.ItemIndex] + '.xml';
end;

procedure TEditForm.cbFileChange(Sender: TObject);
begin
  LoadCurrentFile;
end;

procedure TEditForm.btnReloadClick(Sender: TObject);
begin
  LoadCurrentFile;
end;

procedure TEditForm.LoadCurrentFile;
var
  Doc: TXMLDocument;
  Node: TDOMNode;
  Row: Integer;
  F: string;
begin
  sg.RowCount := 1;
  SetupHeaders;
  F := CurrentFilePath;
  if (F = '') or (not FileExists(F)) then Exit;
  Doc := nil;
  Row := 1;
  try
    try
      ReadXMLFile(Doc, F);
      Node := Doc.DocumentElement.FirstChild;
      while Node <> nil do
      begin
        if (Node.NodeName = 'entry') and (Node.Attributes <> nil) then
        begin
          sg.RowCount := Row + 1;
          if Node.Attributes.GetNamedItem('task') <> nil then
            sg.Cells[0, Row] := Node.Attributes.GetNamedItem('task').NodeValue;
          if Node.Attributes.GetNamedItem('start') <> nil then
            sg.Cells[1, Row] := Node.Attributes.GetNamedItem('start').NodeValue;
          if Node.Attributes.GetNamedItem('end') <> nil then
            sg.Cells[2, Row] := Node.Attributes.GetNamedItem('end').NodeValue;
          if Node.Attributes.GetNamedItem('duration') <> nil then
            sg.Cells[3, Row] := Node.Attributes.GetNamedItem('duration').NodeValue;
          Inc(Row);
        end;
        Node := Node.NextSibling;
      end;
    except
      on E: Exception do
        ShowMessage('Ошибка чтения: ' + E.Message);
    end;
  finally
    Doc.Free;
  end;
end;

procedure TEditForm.sgEditingDone(Sender: TObject);
begin
  if (sg.Row >= 1) and (sg.Row < sg.RowCount) and (sg.Col in [1, 2]) then
    RecalcRow(sg.Row, False);
end;

procedure TEditForm.RecalcRow(R: Integer; Silent: Boolean);
var
  SDT, EDT: TDateTime;
  SS, ES: string;
begin
  if (R < 1) or (R >= sg.RowCount) then Exit;
  SS := Trim(sg.Cells[1, R]);
  ES := Trim(sg.Cells[2, R]);
  if (SS = '') and (ES = '') then Exit;
  if not ParseIso(SS, SDT) then
  begin
    if not Silent then
      ShowMessage('Некорректное время начала: "' + SS + '"' + LineEnding +
                  'Формат: YYYY-MM-DDTHH:MM:SS');
    sg.Cells[3, R] := '';
    Exit;
  end;
  if not ParseIso(ES, EDT) then
  begin
    if not Silent then
      ShowMessage('Некорректное время окончания: "' + ES + '"' + LineEnding +
                  'Формат: YYYY-MM-DDTHH:MM:SS');
    sg.Cells[3, R] := '';
    Exit;
  end;
  if EDT < SDT then
  begin
    if not Silent then
      ShowMessage('Окончание раньше начала');
    sg.Cells[3, R] := '';
    Exit;
  end;
  sg.Cells[3, R] := FormatDateTime(TimeFmt, EDT - SDT);
end;

procedure TEditForm.btnAddClick(Sender: TObject);
var
  R: Integer;
  Now2: TDateTime;
begin
  if cbFile.ItemIndex < 0 then
  begin
    ShowMessage('Сначала выберите файл');
    Exit;
  end;
  sg.RowCount := sg.RowCount + 1;
  R := sg.RowCount - 1;
  Now2 := Now;
  sg.Cells[0, R] := 'Новая задача';
  sg.Cells[1, R] := FormatDateTime(IsoFmt, Now2);
  sg.Cells[2, R] := FormatDateTime(IsoFmt, Now2);
  sg.Cells[3, R] := '00:00:00';
  sg.Row := R;
end;

procedure TEditForm.btnDelClick(Sender: TObject);
begin
  if (sg.Row >= 1) and (sg.Row < sg.RowCount) then
    sg.DeleteRow(sg.Row);
end;

procedure TEditForm.btnSaveClick(Sender: TObject);
var
  Doc: TXMLDocument;
  Root, El: TDOMElement;
  i: Integer;
  F, TaskS, StartS, EndS: string;
  StartDT, EndDT: TDateTime;
  DurMS: Int64;
begin
  F := CurrentFilePath;
  if F = '' then
  begin
    ShowMessage('Файл не выбран');
    Exit;
  end;
  Doc := TXMLDocument.Create;
  try
    Root := Doc.CreateElement('day');
    Root.SetAttribute('date', cbFile.Items[cbFile.ItemIndex]);
    Doc.AppendChild(Root);
    for i := 1 to sg.RowCount - 1 do
    begin
      TaskS  := Trim(sg.Cells[0, i]);
      StartS := Trim(sg.Cells[1, i]);
      EndS   := Trim(sg.Cells[2, i]);
      if (TaskS = '') and (StartS = '') and (EndS = '') then Continue;
      if not ParseIso(StartS, StartDT) then
      begin
        ShowMessage(Format('Строка %d: некорректная дата начала "%s"' + LineEnding +
          'Формат: YYYY-MM-DDTHH:MM:SS', [i, StartS]));
        Exit;
      end;
      if not ParseIso(EndS, EndDT) then
      begin
        ShowMessage(Format('Строка %d: некорректная дата окончания "%s"', [i, EndS]));
        Exit;
      end;
      if EndDT < StartDT then
      begin
        ShowMessage(Format('Строка %d: окончание раньше начала', [i]));
        Exit;
      end;
      DurMS := Round((EndDT - StartDT) * 86400000);
      El := Doc.CreateElement('entry');
      El.SetAttribute('task', TaskS);
      El.SetAttribute('start', StartS);
      El.SetAttribute('end',   EndS);
      El.SetAttribute('duration', FormatDateTime(TimeFmt, EndDT - StartDT));
      El.SetAttribute('durationMs', IntToStr(DurMS));
      Root.AppendChild(El);
    end;
    WriteXMLFile(Doc, F);
    // Sync distinct task names into the global tasks.xml so the main
    // window's dropdown/search sees the fresh names (and picks up any
    // capitalisation change the user just made).
    SyncTasksXmlFromGrid;
    LoadCurrentFile;
    ShowMessage('Сохранено: ' + ExtractFileName(F));
  finally
    Doc.Free;
  end;
end;

procedure TEditForm.SyncTasksXmlFromGrid;
var
  Seen: TStringList;
  i: Integer;
  TaskS, TasksFile: string;
begin
  TasksFile := IncludeTrailingPathDelimiter(FDataDir) + 'tasks.xml';
  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    for i := 1 to sg.RowCount - 1 do
    begin
      TaskS := Trim(sg.Cells[0, i]);
      if TaskS = '' then Continue;
      if Seen.IndexOf(TaskS) >= 0 then Continue;
      Seen.Add(TaskS);
      UpsertTaskName(TasksFile, TaskS);
    end;
  finally
    Seen.Free;
  end;
end;

end.
