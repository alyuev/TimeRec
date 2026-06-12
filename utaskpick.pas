unit utaskpick;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, CheckLst, LazUTF8;

type
  TTaskPickForm = class(TForm)
    btnAll: TButton;
    btnCancel: TButton;
    btnOK: TButton;
    btnReset: TButton;
    edSearch: TEdit;
    lst: TCheckListBox;
    procedure btnAllClick(Sender: TObject);
    procedure btnResetClick(Sender: TObject);
    procedure edSearchChange(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure lstClickCheck(Sender: TObject);
  private
    FNames: array of string;
    FChecked: array of Boolean;
    procedure RebuildList(const Filter: string);
    procedure SyncFromUI;
  public
    procedure SetData(ANames, ASelected: TStrings);
    procedure GetSelected(AOut: TStrings);
  end;

function PickTasks(AOwner: TComponent; ANames, AIn, AOut: TStrings): Boolean;

implementation

{$R *.lfm}

function SplitTokens(const S: string): TStringArray;
var
  i, n, start: Integer;
begin
  Result := nil;
  n := 0; i := 1;
  while i <= Length(S) do
  begin
    while (i <= Length(S)) and (S[i] = ' ') do Inc(i);
    if i > Length(S) then Break;
    start := i;
    while (i <= Length(S)) and (S[i] <> ' ') do Inc(i);
    SetLength(Result, n + 1);
    Result[n] := Copy(S, start, i - start);
    Inc(n);
  end;
end;

function MatchesAll(const LItem: string; const Tokens: TStringArray): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Tokens) do
    if (Tokens[i] <> '') and (Pos(Tokens[i], LItem) = 0) then
      Exit(False);
  Result := True;
end;

procedure TTaskPickForm.SetData(ANames, ASelected: TStrings);
var
  i, sel: Integer;
begin
  SetLength(FNames, ANames.Count);
  SetLength(FChecked, ANames.Count);
  for i := 0 to ANames.Count - 1 do
  begin
    FNames[i] := ANames[i];
    FChecked[i] := False;
    if ASelected <> nil then
    begin
      sel := ASelected.IndexOf(ANames[i]);
      FChecked[i] := sel >= 0;
    end;
  end;
end;

procedure TTaskPickForm.GetSelected(AOut: TStrings);
var
  i: Integer;
begin
  AOut.Clear;
  for i := 0 to High(FNames) do
    if FChecked[i] then AOut.Add(FNames[i]);
end;

procedure TTaskPickForm.RebuildList(const Filter: string);
var
  i: Integer;
  LFilter: string;
  Tokens: TStringArray;
  UseFilter: Boolean;
begin
  LFilter := UTF8LowerCase(Filter);
  UseFilter := UTF8Length(Filter) >= 3;
  if UseFilter then Tokens := SplitTokens(LFilter);

  lst.Items.BeginUpdate;
  try
    lst.Items.Clear;
    for i := 0 to High(FNames) do
      if (not UseFilter) or MatchesAll(UTF8LowerCase(FNames[i]), Tokens) then
      begin
        lst.Items.AddObject(FNames[i], TObject(PtrInt(i)));
        lst.Checked[lst.Items.Count - 1] := FChecked[i];
      end;
  finally
    lst.Items.EndUpdate;
  end;
end;

procedure TTaskPickForm.SyncFromUI;
var
  i, idx: Integer;
begin
  for i := 0 to lst.Items.Count - 1 do
  begin
    idx := PtrInt(lst.Items.Objects[i]);
    if (idx >= 0) and (idx <= High(FChecked)) then
      FChecked[idx] := lst.Checked[i];
  end;
end;

procedure TTaskPickForm.FormShow(Sender: TObject);
begin
  Caption := 'Выбор задач';
  edSearch.TextHint := 'Поиск (от 3 символов)...';
  btnAll.Hint := 'Отметить все';
  btnReset.Hint := 'Снять все';
  btnCancel.Caption := 'Отмена';
  edSearch.Text := '';
  RebuildList('');
end;

procedure TTaskPickForm.edSearchChange(Sender: TObject);
begin
  SyncFromUI;
  RebuildList(edSearch.Text);
end;

procedure TTaskPickForm.lstClickCheck(Sender: TObject);
begin
  SyncFromUI;
end;

procedure TTaskPickForm.btnAllClick(Sender: TObject);
var
  i, idx: Integer;
begin
  // Отмечаем всё, что сейчас видно в списке (с учётом фильтра поиска).
  // Если фильтр пустой — отмечает абсолютно всё.
  for i := 0 to lst.Items.Count - 1 do
  begin
    idx := PtrInt(lst.Items.Objects[i]);
    if (idx >= 0) and (idx <= High(FChecked)) then
      FChecked[idx] := True;
  end;
  RebuildList(edSearch.Text);
end;

procedure TTaskPickForm.btnResetClick(Sender: TObject);
var
  i: Integer;
begin
  for i := 0 to High(FChecked) do FChecked[i] := False;
  RebuildList(edSearch.Text);
end;

function PickTasks(AOwner: TComponent; ANames, AIn, AOut: TStrings): Boolean;
var
  Frm: TTaskPickForm;
  Parent: TCustomForm;
  ScrW: Integer;
begin
  Frm := TTaskPickForm.Create(AOwner);
  try
    Frm.SetData(ANames, AIn);
    // Attach to the right edge of the owning form
    if (AOwner is TCustomForm) then Parent := TCustomForm(AOwner) else Parent := nil;
    if Parent <> nil then
    begin
      Frm.Left := Parent.Left + Parent.Width;
      Frm.Top  := Parent.Top;
      ScrW := Screen.Width;
      if Frm.Left + Frm.Width > ScrW then
        Frm.Left := Parent.Left - Frm.Width;
      if Frm.Left < 0 then Frm.Left := 0;
    end;
    Result := Frm.ShowModal = mrOK;
    if Result then Frm.GetSelected(AOut);
  finally
    Frm.Free;
  end;
end;

end.
