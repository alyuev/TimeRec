unit uaisettings;

// AI-transcription settings dialog. Built programmatically — no LFM,
// no Cyrillic-encoding mess.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, Dialogs, uai;

function EditAISettings(var Settings: TAISettings): Boolean;

implementation

uses
  fpjson, jsonparser;

type
  TAISettingsForm = class(TForm)
  public
    edEndpoint, edKey, edModel, edLang: TEdit;
    chkEnabled: TCheckBox;
    lblInfo: TLabel;
    procedure DoTest(Sender: TObject);
  end;

procedure TAISettingsForm.DoTest(Sender: TObject);
var
  S: TAISettings;
  Url, Resp, Names: string;
  Status, i: Integer;
  Ok: Boolean;
  J: TJSONData;
  Arr: TJSONArray;
begin
  S.Endpoint := Trim(edEndpoint.Text);
  S.ApiKey := edKey.Text;
  if S.Endpoint = '' then
  begin
    lblInfo.Caption := 'Заполните URL.';
    Exit;
  end;
  Url := S.Endpoint;
  if Url[Length(Url)] = '/' then SetLength(Url, Length(Url) - 1);
  Url := Url + '/models';
  lblInfo.Caption := 'Проверяю...';
  Application.ProcessMessages;
  Ok := HttpGetJson(Url, S.ApiKey, Resp, Status);
  if not Ok then
  begin
    lblInfo.Caption := 'Не отвечает (HTTP ' + IntToStr(Status) + '): ' +
      Copy(Resp, 1, 250);
    Exit;
  end;
  Names := '';
  try
    J := GetJSON(Resp);
    try
      if (J is TJSONObject) and (TJSONObject(J).Find('data') is TJSONArray) then
      begin
        Arr := TJSONArray(TJSONObject(J).Find('data'));
        for i := 0 to Arr.Count - 1 do
          if (Arr.Items[i] is TJSONObject) and
             (TJSONObject(Arr.Items[i]).Find('id') <> nil) then
          begin
            if Names <> '' then Names := Names + ', ';
            Names := Names + TJSONObject(Arr.Items[i]).Get('id', '');
            if i >= 9 then begin Names := Names + ', ...'; Break; end;
          end;
      end;
    finally
      J.Free;
    end;
  except
  end;
  if Names <> '' then
    lblInfo.Caption := 'OK. Модели: ' + Names
  else
    lblInfo.Caption := 'OK (HTTP ' + IntToStr(Status) + '). Список моделей не распознан.';
end;

function EditAISettings(var Settings: TAISettings): Boolean;
var
  F: TAISettingsForm;
  lblHelp, lblEndpoint, lblKey, lblModel, lblLang: TLabel;
  btnTest, btnOK, btnCancel: TButton;
begin
  Result := False;
  F := TAISettingsForm.CreateNew(nil);
  try
    F.Caption := 'ИИ-расшифровка — настройки';
    F.BorderStyle := bsDialog;
    F.Position := poScreenCenter;
    F.ClientWidth := 520;
    F.ClientHeight := 360;

    lblHelp := TLabel.Create(F);
    lblHelp.Parent := F;
    lblHelp.SetBounds(12, 8, 496, 36);
    lblHelp.AutoSize := False;
    lblHelp.WordWrap := True;
    lblHelp.Caption :=
      'OpenAI-совместимый аудио-эндпоинт. Поддерживаются LM Studio, ' +
      'Lemonade, whisper.cpp-server, OpenAI Cloud. Ollama не подходит — ' +
      'у неё нет Whisper.';

    lblEndpoint := TLabel.Create(F);
    lblEndpoint.Parent := F;
    lblEndpoint.SetBounds(12, 56, 80, 18);
    lblEndpoint.Caption := 'URL:';

    F.edEndpoint := TEdit.Create(F);
    F.edEndpoint.Parent := F;
    F.edEndpoint.SetBounds(100, 52, 408, 24);
    F.edEndpoint.TextHint := 'http://localhost:1234/v1';
    F.edEndpoint.Text := Settings.Endpoint;

    lblKey := TLabel.Create(F);
    lblKey.Parent := F;
    lblKey.SetBounds(12, 92, 80, 18);
    lblKey.Caption := 'API-ключ:';

    F.edKey := TEdit.Create(F);
    F.edKey.Parent := F;
    F.edKey.SetBounds(100, 88, 408, 24);
    F.edKey.TextHint := 'не нужен для local-серверов';
    F.edKey.Text := Settings.ApiKey;
    F.edKey.PasswordChar := '*';

    lblModel := TLabel.Create(F);
    lblModel.Parent := F;
    lblModel.SetBounds(12, 128, 80, 18);
    lblModel.Caption := 'Модель:';

    F.edModel := TEdit.Create(F);
    F.edModel.Parent := F;
    F.edModel.SetBounds(100, 124, 408, 24);
    F.edModel.TextHint := 'whisper-1 / faster-whisper-large-v3';
    F.edModel.Text := Settings.Model;

    lblLang := TLabel.Create(F);
    lblLang.Parent := F;
    lblLang.SetBounds(12, 164, 80, 18);
    lblLang.Caption := 'Язык:';

    F.edLang := TEdit.Create(F);
    F.edLang.Parent := F;
    F.edLang.SetBounds(100, 160, 80, 24);
    F.edLang.TextHint := 'авто';
    F.edLang.Text := Settings.Language;

    F.chkEnabled := TCheckBox.Create(F);
    F.chkEnabled.Parent := F;
    F.chkEnabled.SetBounds(12, 198, 496, 24);
    F.chkEnabled.Caption := 'Подключение активно — показывать кнопку «Расшифровать»';
    F.chkEnabled.Checked := Settings.Enabled;

    btnTest := TButton.Create(F);
    btnTest.Parent := F;
    btnTest.SetBounds(12, 232, 180, 28);
    btnTest.Caption := 'Проверить соединение';
    btnTest.OnClick := @F.DoTest;

    F.lblInfo := TLabel.Create(F);
    F.lblInfo.Parent := F;
    F.lblInfo.SetBounds(12, 268, 496, 50);
    F.lblInfo.AutoSize := False;
    F.lblInfo.WordWrap := True;
    F.lblInfo.Caption := '';

    btnOK := TButton.Create(F);
    btnOK.Parent := F;
    btnOK.SetBounds(330, 322, 88, 30);
    btnOK.Caption := 'OK';
    btnOK.ModalResult := mrOK;
    btnOK.Default := True;

    btnCancel := TButton.Create(F);
    btnCancel.Parent := F;
    btnCancel.SetBounds(424, 322, 88, 30);
    btnCancel.Caption := 'Отмена';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;

    if F.ShowModal = mrOK then
    begin
      Settings.Endpoint := Trim(F.edEndpoint.Text);
      Settings.ApiKey := F.edKey.Text;
      Settings.Model := Trim(F.edModel.Text);
      Settings.Language := Trim(F.edLang.Text);
      Settings.Enabled := F.chkEnabled.Checked;
      Result := True;
    end;
  finally
    F.Free;
  end;
end;

end.
