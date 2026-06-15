unit uaitext;

// Transcription text viewer with copy-to-clipboard. Built
// programmatically.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Clipbrd;

procedure ShowTranscript(const ATitle, AText: string);
procedure ShowTranscriptFile(const Path: string);

implementation

type
  TAITextForm = class(TForm)
  public
    mmo: TMemo;
    procedure DoCopy(Sender: TObject);
  end;

procedure TAITextForm.DoCopy(Sender: TObject);
begin
  Clipboard.AsText := mmo.Text;
end;

procedure ShowTranscript(const ATitle, AText: string);
var
  F: TAITextForm;
  btnCopy, btnClose: TButton;
begin
  F := TAITextForm.CreateNew(nil);
  try
    F.Caption := 'TimeRec — ' + ATitle;
    F.BorderStyle := bsSizeable;
    F.Position := poScreenCenter;
    F.ClientWidth := 680;
    F.ClientHeight := 480;

    F.mmo := TMemo.Create(F);
    F.mmo.Parent := F;
    F.mmo.SetBounds(8, 8, 664, 432);
    F.mmo.Anchors := [akTop, akLeft, akRight, akBottom];
    F.mmo.ScrollBars := ssAutoVertical;
    F.mmo.WordWrap := True;
    F.mmo.ReadOnly := False;  // allow user edit/select
    F.mmo.Font.Name := 'Segoe UI';
    F.mmo.Font.Height := -14;
    F.mmo.Lines.Text := AText;

    btnCopy := TButton.Create(F);
    btnCopy.Parent := F;
    btnCopy.SetBounds(8, 446, 160, 28);
    btnCopy.Anchors := [akLeft, akBottom];
    btnCopy.Caption := 'Скопировать в буфер';
    btnCopy.OnClick := @F.DoCopy;

    btnClose := TButton.Create(F);
    btnClose.Parent := F;
    btnClose.SetBounds(584, 446, 88, 28);
    btnClose.Anchors := [akRight, akBottom];
    btnClose.Caption := 'Закрыть';
    btnClose.ModalResult := mrClose;
    btnClose.Cancel := True;

    F.ShowModal;
  finally
    F.Free;
  end;
end;

procedure ShowTranscriptFile(const Path: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    ShowTranscript('Расшифровка ' + ExtractFileName(Path), L.Text);
  finally
    L.Free;
  end;
end;

end.
