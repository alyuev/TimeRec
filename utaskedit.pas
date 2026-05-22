unit utaskedit;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ExtCtrls, Grids, Dialogs;

type
  TTasksEditForm = class(TForm)
    btnAdd: TButton;
    btnClose: TButton;
    btnDel: TButton;
    btnSave: TButton;
    pnlBottom: TPanel;
    sg: TStringGrid;
    procedure btnAddClick(Sender: TObject);
    procedure btnCloseClick(Sender: TObject);
    procedure btnDelClick(Sender: TObject);
    procedure btnSaveClick(Sender: TObject);
    procedure FormShow(Sender: TObject);
  private
    FFile: string;
    procedure LoadFromFile;
  public
    procedure ShowFor(const ATasksFile: string);
  end;

var
  TasksEditForm: TTasksEditForm;

implementation

uses
  DOM, XMLRead, XMLWrite;

{$R *.lfm}

procedure TTasksEditForm.ShowFor(const ATasksFile: string);
begin
  FFile := ATasksFile;
  Show;
  BringToFront;
end;

procedure TTasksEditForm.FormShow(Sender: TObject);
begin
  sg.Cells[0, 0] := 'Задача';
  sg.Cells[1, 0] := 'Вид';
  LoadFromFile;
end;

procedure TTasksEditForm.LoadFromFile;
var
  Doc: TXMLDocument;
  Node: TDOMNode;
  Row: Integer;
  NameS, Kind: string;
begin
  sg.RowCount := 1;
  if not FileExists(FFile) then Exit;
  Doc := nil;
  Row := 1;
  try
    try
      ReadXMLFile(Doc, FFile);
      Node := Doc.DocumentElement.FirstChild;
      while Node <> nil do
      begin
        if (Node.NodeName = 'task') and (Node.Attributes <> nil)
           and (Node.Attributes.GetNamedItem('name') <> nil) then
        begin
          NameS := Node.Attributes.GetNamedItem('name').NodeValue;
          if Node.Attributes.GetNamedItem('kind') <> nil then
            Kind := Node.Attributes.GetNamedItem('kind').NodeValue
          else
            Kind := '';
          sg.RowCount := Row + 1;
          sg.Cells[0, Row] := NameS;
          sg.Cells[1, Row] := Kind;
          Inc(Row);
        end;
        Node := Node.NextSibling;
      end;
    except
    end;
  finally
    Doc.Free;
  end;
end;

procedure TTasksEditForm.btnAddClick(Sender: TObject);
begin
  sg.RowCount := sg.RowCount + 1;
  sg.Row := sg.RowCount - 1;
  sg.Cells[0, sg.Row] := '';
  sg.Cells[1, sg.Row] := '';
  sg.Col := 0;
end;

procedure TTasksEditForm.btnDelClick(Sender: TObject);
var
  S: string;
begin
  if (sg.Row < 1) or (sg.Row >= sg.RowCount) then Exit;
  S := Trim(sg.Cells[0, sg.Row]);
  if S = '' then S := '(пустая строка)';
  if MessageDlg('Удалить задание', 'Удалить «' + S + '»?',
       mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    sg.DeleteRow(sg.Row);
end;

procedure TTasksEditForm.btnSaveClick(Sender: TObject);
var
  Doc: TXMLDocument;
  Root, OldRoot, El, OldEl: TDOMElement;
  OldNode: TDOMNode;
  i: Integer;
  NameS, Kind, LastUsed: string;
  PrevKinds, PrevLast: TStringList;
begin
  // Read existing file to preserve lastUsed timestamps per task
  PrevKinds := TStringList.Create;
  PrevLast := TStringList.Create;
  try
    PrevKinds.CaseSensitive := True;
    PrevLast.CaseSensitive := True;
    if FileExists(FFile) then
    begin
      Doc := nil;
      try
        ReadXMLFile(Doc, FFile);
        OldRoot := Doc.DocumentElement;
        OldNode := OldRoot.FirstChild;
        while OldNode <> nil do
        begin
          if (OldNode.NodeName = 'task') and (OldNode.Attributes <> nil)
             and (OldNode.Attributes.GetNamedItem('name') <> nil) then
          begin
            NameS := OldNode.Attributes.GetNamedItem('name').NodeValue;
            if OldNode.Attributes.GetNamedItem('lastUsed') <> nil then
              LastUsed := OldNode.Attributes.GetNamedItem('lastUsed').NodeValue
            else
              LastUsed := '';
            PrevLast.Values[NameS] := LastUsed;
          end;
          OldNode := OldNode.NextSibling;
        end;
      finally
        Doc.Free;
      end;
    end;

    Doc := TXMLDocument.Create;
    try
      Root := Doc.CreateElement('tasks');
      Doc.AppendChild(Root);
      for i := 1 to sg.RowCount - 1 do
      begin
        NameS := Trim(sg.Cells[0, i]);
        Kind := Trim(sg.Cells[1, i]);
        if NameS = '' then Continue;
        El := Doc.CreateElement('task');
        El.SetAttribute('name', NameS);
        if Kind <> '' then
          El.SetAttribute('kind', Kind);
        LastUsed := PrevLast.Values[NameS];
        if LastUsed <> '' then
          El.SetAttribute('lastUsed', LastUsed);
        Root.AppendChild(El);
      end;
      WriteXMLFile(Doc, FFile);
    finally
      Doc.Free;
    end;
  finally
    PrevKinds.Free;
    PrevLast.Free;
  end;
end;

procedure TTasksEditForm.btnCloseClick(Sender: TObject);
begin
  Close;
end;

end.
