unit uaisettings;

// Whisper transcription settings dialog: download backend (CPU/Vulkan/
// CUDA), download models, pick language. Built programmatically.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, StdCtrls, ComCtrls, Dialogs, Graphics,
  uwhisper, uai;

function EditWhisperSettings(var S: TWhisperSettings;
  const AppDir: string): Boolean;

type
  TModelInfo = record
    Name: string;     // shown to user
    FileName: string; // ggml-*.bin
    SizeMB: Integer;  // approx
  end;

const
  KnownModels: array[0..4] of TModelInfo = (
    (Name: 'tiny (~30 МБ)';                        FileName: 'ggml-tiny-q5_1.bin';            SizeMB: 32),
    (Name: 'base (~60 МБ)';                        FileName: 'ggml-base-q5_1.bin';            SizeMB: 60),
    (Name: 'small (~190 МБ)';                      FileName: 'ggml-small-q5_1.bin';           SizeMB: 190),
    (Name: 'medium (~530 МБ)';                     FileName: 'ggml-medium-q5_0.bin';          SizeMB: 530),
    (Name: 'large-v3-turbo (~870 МБ, рекомендуется)'; FileName: 'ggml-large-v3-turbo-q5_0.bin'; SizeMB: 870)
  );

implementation

uses
  Zipper;

const
  DefaultDllBaseUrl   = 'https://github.com/ggml-org/whisper.cpp/releases/latest/download/';
  DefaultModelBaseUrl = 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/';

type
  TDownloadKind = (dkBackendCPU, dkBackendVulkan, dkBackendCUDA, dkModel);

  TWhisperSettingsForm = class(TForm)
  public
    edLang, edDllUrl, edModelUrl: TEdit;
    cbModel: TComboBox;
    chkEnabled: TCheckBox;
    lblStatus: TLabel;
    lblProgress: TLabel;
    pb: TProgressBar;
    btnCPU, btnVulkan, btnCUDA, btnDownloadModel: TButton;
    FAppDir: string;
    FBusy: Boolean;
    procedure DoBackendCPU(Sender: TObject);
    procedure DoBackendVulkan(Sender: TObject);
    procedure DoBackendCUDA(Sender: TObject);
    procedure DoModelDownload(Sender: TObject);
    procedure DoModelChange(Sender: TObject);
    procedure RefreshStatus;
    procedure StartBackendDownload(Kind: TDownloadKind);
    procedure StartModelDownload(const FileName: string);
    procedure UpdateProgress(BytesRead, BytesTotal: Int64);
    procedure DoneBackend(const DestZip, BackendDir: string;
      Ok: Boolean; const ErrMsg: string);
    procedure DoneModel(const FileName: string; Ok: Boolean;
      const ErrMsg: string);
  end;

  TBackendDownloadThread = class(TThread)
  private
    FForm: TWhisperSettingsForm;
    FKind: TDownloadKind;
    FAssetWildcard: string;
    FBaseUrl: string;
    FBackendDir: string;
    FZipPath: string;
    FOk: Boolean;
    FErrMsg: string;
    procedure DoFinish;
    procedure OnProg(Read, Total: Int64);
    procedure DoProg;
  private
    FProgRead, FProgTotal: Int64;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TWhisperSettingsForm; AKind: TDownloadKind;
      const AAssetWildcard, ABaseUrl, ABackendDir: string);
  end;

  TModelDownloadThread = class(TThread)
  private
    FForm: TWhisperSettingsForm;
    FFileName: string;
    FUrl: string;
    FDest: string;
    FOk: Boolean;
    FErrMsg: string;
    procedure DoFinish;
    procedure OnProg(Read, Total: Int64);
    procedure DoProg;
  private
    FProgRead, FProgTotal: Int64;
  protected
    procedure Execute; override;
  public
    constructor Create(AForm: TWhisperSettingsForm; const AFileName,
      AUrl, ADest: string);
  end;

{ TBackendDownloadThread }

constructor TBackendDownloadThread.Create(AForm: TWhisperSettingsForm;
  AKind: TDownloadKind; const AAssetWildcard, ABaseUrl,
  ABackendDir: string);
begin
  FForm := AForm;
  FKind := AKind;
  FAssetWildcard := AAssetWildcard;
  FBaseUrl := ABaseUrl;
  FBackendDir := ABackendDir;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TBackendDownloadThread.OnProg(Read, Total: Int64);
begin
  FProgRead := Read; FProgTotal := Total;
  Synchronize(@DoProg);
end;

procedure TBackendDownloadThread.DoProg;
begin
  FForm.UpdateProgress(FProgRead, FProgTotal);
end;

procedure TBackendDownloadThread.Execute;
var
  AssetUrl, AssetName, Err: string;
  DR: TDownloadResult;
begin
  FOk := False;
  // First try GitHub API to find latest asset matching wildcard. If
  // user overrode the base URL to something non-GitHub, fall back to
  // BaseUrl + a guess at the filename (only works for CPU/Vulkan with
  // stable names).
  if Pos('github.com/ggml-org/whisper.cpp', FBaseUrl) > 0 then
  begin
    if not GitHubLatestAssetUrl('ggml-org', 'whisper.cpp', FAssetWildcard,
         AssetUrl, AssetName, Err) then
    begin
      FErrMsg := Err;
      Synchronize(@DoFinish);
      Exit;
    end;
  end
  else
  begin
    // Fallback — caller's responsibility to give a working URL
    AssetUrl := IncludeTrailingPathDelimiter(FBaseUrl) +
      StringReplace(FAssetWildcard, '*', '', [rfReplaceAll]);
    AssetName := ExtractFileName(AssetUrl);
  end;
  FZipPath := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'timerec_whisper_' + AssetName;
  DR := HttpDownloadFile(AssetUrl, FZipPath, @OnProg);
  FOk := DR.Ok;
  if not FOk then FErrMsg := DR.ErrorMsg;
  Synchronize(@DoFinish);
end;

procedure TBackendDownloadThread.DoFinish;
begin
  FForm.DoneBackend(FZipPath, FBackendDir, FOk, FErrMsg);
end;

{ TModelDownloadThread }

constructor TModelDownloadThread.Create(AForm: TWhisperSettingsForm;
  const AFileName, AUrl, ADest: string);
begin
  FForm := AForm;
  FFileName := AFileName;
  FUrl := AUrl;
  FDest := ADest;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TModelDownloadThread.OnProg(Read, Total: Int64);
begin
  FProgRead := Read; FProgTotal := Total;
  Synchronize(@DoProg);
end;

procedure TModelDownloadThread.DoProg;
begin
  FForm.UpdateProgress(FProgRead, FProgTotal);
end;

procedure TModelDownloadThread.Execute;
var
  DR: TDownloadResult;
begin
  DR := HttpDownloadFile(FUrl, FDest, @OnProg);
  FOk := DR.Ok;
  if not FOk then FErrMsg := DR.ErrorMsg;
  Synchronize(@DoFinish);
end;

procedure TModelDownloadThread.DoFinish;
begin
  FForm.DoneModel(FFileName, FOk, FErrMsg);
end;

{ TWhisperSettingsForm }

procedure TWhisperSettingsForm.RefreshStatus;
var
  Backend: TWhisperBackend;
  S: string;
  BackendDir: string;
begin
  BackendDir := IncludeTrailingPathDelimiter(FAppDir) + 'whisper';
  Backend := DetectBackend(BackendDir);
  if Backend = wbNone then
    S := 'Whisper-движок: НЕ УСТАНОВЛЕН. Скачайте один из вариантов ниже.'
  else
    S := 'Whisper-движок установлен: ' + BackendName(Backend) +
         ' (' + BackendDir + ')';
  lblStatus.Caption := S;
end;

procedure TWhisperSettingsForm.UpdateProgress(BytesRead, BytesTotal: Int64);
var Pct: Integer;
begin
  if BytesTotal > 0 then
  begin
    Pct := Round(BytesRead * 100 / BytesTotal);
    if Pct < 0 then Pct := 0; if Pct > 100 then Pct := 100;
    pb.Position := Pct;
    lblProgress.Caption := Format('Скачано %d / %d МБ (%d%%)',
      [BytesRead div (1024*1024), BytesTotal div (1024*1024), Pct]);
  end
  else
  begin
    pb.Position := 0;
    lblProgress.Caption := Format('Скачано %d МБ', [BytesRead div (1024*1024)]);
  end;
end;

procedure TWhisperSettingsForm.StartBackendDownload(Kind: TDownloadKind);
var
  Wildcard, BackendDir: string;
begin
  if FBusy then Exit;
  case Kind of
    dkBackendCPU:    Wildcard := 'whisper-bin-x64.zip';
    dkBackendVulkan: Wildcard := 'whisper-vulkan-bin-x64.zip';
    dkBackendCUDA:   Wildcard := 'whisper-cublas-*-bin-x64.zip';
  end;
  BackendDir := IncludeTrailingPathDelimiter(FAppDir) + 'whisper';
  ForceDirectories(BackendDir);
  FBusy := True;
  btnCPU.Enabled := False;
  btnVulkan.Enabled := False;
  btnCUDA.Enabled := False;
  btnDownloadModel.Enabled := False;
  pb.Position := 0;
  lblProgress.Caption := 'Запрашиваю информацию о релизе...';
  TBackendDownloadThread.Create(Self, Kind, Wildcard,
    edDllUrl.Text, BackendDir);
end;

procedure TWhisperSettingsForm.DoBackendCPU(Sender: TObject);
begin
  StartBackendDownload(dkBackendCPU);
end;

procedure TWhisperSettingsForm.DoBackendVulkan(Sender: TObject);
begin
  StartBackendDownload(dkBackendVulkan);
end;

procedure TWhisperSettingsForm.DoBackendCUDA(Sender: TObject);
begin
  StartBackendDownload(dkBackendCUDA);
end;

procedure TWhisperSettingsForm.DoneBackend(const DestZip, BackendDir: string;
  Ok: Boolean; const ErrMsg: string);
var
  Count: Integer;
  Err: string;
begin
  FBusy := False;
  btnCPU.Enabled := True;
  btnVulkan.Enabled := True;
  btnCUDA.Enabled := True;
  btnDownloadModel.Enabled := True;
  if not Ok then
  begin
    lblProgress.Caption := 'Ошибка: ' + ErrMsg;
    Exit;
  end;
  lblProgress.Caption := 'Распаковка...';
  Application.ProcessMessages;
  if not UnzipFlat(DestZip, BackendDir, Count, Err) then
  begin
    lblProgress.Caption := 'Ошибка распаковки: ' + Err;
    Exit;
  end;
  DeleteFile(DestZip);
  lblProgress.Caption := 'Готово, распаковано файлов: ' + IntToStr(Count);
  RefreshStatus;
end;

procedure TWhisperSettingsForm.DoModelDownload(Sender: TObject);
var
  Idx: Integer;
  FName, Url, Dest: string;
begin
  if FBusy then Exit;
  Idx := cbModel.ItemIndex;
  if (Idx < 0) or (Idx > High(KnownModels)) then
  begin
    lblProgress.Caption := 'Выберите модель';
    Exit;
  end;
  FName := KnownModels[Idx].FileName;
  Url := IncludeTrailingPathDelimiter(StringReplace(edModelUrl.Text, '\', '/',
         [rfReplaceAll])) + FName;
  Dest := IncludeTrailingPathDelimiter(FAppDir) + 'models' + PathDelim + FName;
  FBusy := True;
  btnCPU.Enabled := False;
  btnVulkan.Enabled := False;
  btnCUDA.Enabled := False;
  btnDownloadModel.Enabled := False;
  pb.Position := 0;
  lblProgress.Caption := 'Скачиваю модель ' + FName + '...';
  StartModelDownload(FName);
  TModelDownloadThread.Create(Self, FName, Url, Dest);
end;

procedure TWhisperSettingsForm.StartModelDownload(const FileName: string);
begin
  // Marker — actual work happens in the thread constructed by caller.
  // Kept as a separate method for symmetry with backend download.
end;

procedure TWhisperSettingsForm.DoneModel(const FileName: string;
  Ok: Boolean; const ErrMsg: string);
begin
  FBusy := False;
  btnCPU.Enabled := True;
  btnVulkan.Enabled := True;
  btnCUDA.Enabled := True;
  btnDownloadModel.Enabled := True;
  if Ok then
    lblProgress.Caption := 'Модель ' + FileName + ' скачана.'
  else
    lblProgress.Caption := 'Ошибка модели: ' + ErrMsg;
end;

procedure TWhisperSettingsForm.DoModelChange(Sender: TObject);
begin
  // Could refresh "installed" indicator per model. Skipped for v1.
end;

function EditWhisperSettings(var S: TWhisperSettings;
  const AppDir: string): Boolean;
var
  F: TWhisperSettingsForm;
  lbl1, lbl2, lbl3, lbl4, lblHelp, lblModelHdr, lblLang, lblAdv: TLabel;
  btnOK, btnCancel: TButton;
  i, Selected: Integer;
  D: string;
begin
  Result := False;
  F := TWhisperSettingsForm.CreateNew(nil);
  try
    F.FAppDir := AppDir;
    F.FBusy := False;
    F.Caption := 'Расшифровка аудио (Whisper) — настройки';
    F.BorderStyle := bsDialog;
    F.Position := poScreenCenter;
    F.ClientWidth := 640;
    F.ClientHeight := 540;

    lblHelp := TLabel.Create(F);
    lblHelp.Parent := F;
    lblHelp.SetBounds(12, 8, 616, 36);
    lblHelp.AutoSize := False;
    lblHelp.WordWrap := True;
    lblHelp.Caption :=
      'Локальная расшифровка через whisper.cpp. Полностью офлайн, ' +
      'после скачивания движка и модели интернет не нужен.';

    lbl1 := TLabel.Create(F);
    lbl1.Parent := F;
    lbl1.SetBounds(12, 48, 616, 18);
    lbl1.Caption := '1. Whisper-движок';
    lbl1.Font.Style := [fsBold];

    F.lblStatus := TLabel.Create(F);
    F.lblStatus.Parent := F;
    F.lblStatus.SetBounds(12, 68, 616, 18);
    F.RefreshStatus;

    F.btnCPU := TButton.Create(F);
    F.btnCPU.Parent := F;
    F.btnCPU.SetBounds(12, 92, 196, 28);
    F.btnCPU.Caption := 'Скачать CPU-вариант';
    F.btnCPU.OnClick := @F.DoBackendCPU;

    F.btnVulkan := TButton.Create(F);
    F.btnVulkan.Parent := F;
    F.btnVulkan.SetBounds(218, 92, 196, 28);
    F.btnVulkan.Caption := 'Vulkan (AMD/NVIDIA/Intel)';
    F.btnVulkan.OnClick := @F.DoBackendVulkan;

    F.btnCUDA := TButton.Create(F);
    F.btnCUDA.Parent := F;
    F.btnCUDA.SetBounds(424, 92, 196, 28);
    F.btnCUDA.Caption := 'CUDA (NVIDIA)';
    F.btnCUDA.OnClick := @F.DoBackendCUDA;

    lbl2 := TLabel.Create(F);
    lbl2.Parent := F;
    lbl2.SetBounds(12, 132, 616, 18);
    lbl2.Caption := '2. Модель';
    lbl2.Font.Style := [fsBold];

    lblModelHdr := TLabel.Create(F);
    lblModelHdr.Parent := F;
    lblModelHdr.SetBounds(12, 152, 616, 18);
    lblModelHdr.Caption :=
      'Чем больше модель — тем выше качество и медленнее обработка.';

    F.cbModel := TComboBox.Create(F);
    F.cbModel.Parent := F;
    F.cbModel.SetBounds(12, 176, 408, 24);
    F.cbModel.Style := csDropDownList;
    Selected := -1;
    for i := 0 to High(KnownModels) do
    begin
      F.cbModel.Items.Add(KnownModels[i].Name);
      if SameText(KnownModels[i].FileName, S.ModelFile) then Selected := i;
    end;
    if Selected < 0 then Selected := High(KnownModels);  // default: large-turbo
    F.cbModel.ItemIndex := Selected;
    F.cbModel.OnChange := @F.DoModelChange;

    F.btnDownloadModel := TButton.Create(F);
    F.btnDownloadModel.Parent := F;
    F.btnDownloadModel.SetBounds(430, 174, 190, 28);
    F.btnDownloadModel.Caption := 'Скачать выбранную';
    F.btnDownloadModel.OnClick := @F.DoModelDownload;

    lbl3 := TLabel.Create(F);
    lbl3.Parent := F;
    lbl3.SetBounds(12, 218, 616, 18);
    lbl3.Caption := '3. Прогресс скачивания';
    lbl3.Font.Style := [fsBold];

    F.pb := TProgressBar.Create(F);
    F.pb.Parent := F;
    F.pb.SetBounds(12, 238, 616, 18);
    F.pb.Min := 0; F.pb.Max := 100;

    F.lblProgress := TLabel.Create(F);
    F.lblProgress.Parent := F;
    F.lblProgress.SetBounds(12, 262, 616, 18);
    F.lblProgress.Caption := '';

    lbl4 := TLabel.Create(F);
    lbl4.Parent := F;
    lbl4.SetBounds(12, 290, 616, 18);
    lbl4.Caption := '4. Язык и активация';
    lbl4.Font.Style := [fsBold];

    lblLang := TLabel.Create(F);
    lblLang.Parent := F;
    lblLang.SetBounds(12, 312, 80, 18);
    lblLang.Caption := 'Язык:';

    F.edLang := TEdit.Create(F);
    F.edLang.Parent := F;
    F.edLang.SetBounds(96, 308, 80, 24);
    F.edLang.TextHint := 'авто / ru / en';
    F.edLang.Text := S.Language;

    F.chkEnabled := TCheckBox.Create(F);
    F.chkEnabled.Parent := F;
    F.chkEnabled.SetBounds(12, 340, 616, 24);
    F.chkEnabled.Caption := 'Активно — показывать кнопку расшифровки';
    F.chkEnabled.Checked := S.Enabled;

    lblAdv := TLabel.Create(F);
    lblAdv.Parent := F;
    lblAdv.SetBounds(12, 374, 616, 18);
    lblAdv.Caption := 'Дополнительно: адреса для скачивания';

    F.edDllUrl := TEdit.Create(F);
    F.edDllUrl.Parent := F;
    F.edDllUrl.SetBounds(12, 394, 616, 24);
    if S.DllBaseUrl <> '' then F.edDllUrl.Text := S.DllBaseUrl
    else F.edDllUrl.Text := DefaultDllBaseUrl;

    F.edModelUrl := TEdit.Create(F);
    F.edModelUrl.Parent := F;
    F.edModelUrl.SetBounds(12, 424, 616, 24);
    if S.ModelBaseUrl <> '' then F.edModelUrl.Text := S.ModelBaseUrl
    else F.edModelUrl.Text := DefaultModelBaseUrl;

    btnOK := TButton.Create(F);
    btnOK.Parent := F;
    btnOK.SetBounds(450, 500, 88, 30);
    btnOK.Caption := 'OK';
    btnOK.ModalResult := mrOK;
    btnOK.Default := True;

    btnCancel := TButton.Create(F);
    btnCancel.Parent := F;
    btnCancel.SetBounds(544, 500, 88, 30);
    btnCancel.Caption := 'Отмена';
    btnCancel.ModalResult := mrCancel;
    btnCancel.Cancel := True;

    if F.ShowModal = mrOK then
    begin
      S.BackendDir := IncludeTrailingPathDelimiter(AppDir) + 'whisper';
      S.ModelsDir := IncludeTrailingPathDelimiter(AppDir) + 'models';
      if (F.cbModel.ItemIndex >= 0) and
         (F.cbModel.ItemIndex <= High(KnownModels)) then
        S.ModelFile := KnownModels[F.cbModel.ItemIndex].FileName;
      S.Language := Trim(F.edLang.Text);
      S.Enabled := F.chkEnabled.Checked;
      S.DllBaseUrl := Trim(F.edDllUrl.Text);
      S.ModelBaseUrl := Trim(F.edModelUrl.Text);
      Result := True;
    end;
  finally
    F.Free;
  end;
end;

end.
