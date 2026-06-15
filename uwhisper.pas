unit uwhisper;

// Local Whisper transcription via the whisper.cpp CLI binary
// (whisper-cli.exe, formerly main.exe). User installs the whisper.cpp
// release ZIP into a "whisper" subfolder via the settings dialog; we
// look it up at runtime. MP3 is decoded to PCM WAV via the bundled
// ffmpeg.exe before invocation.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, Windows;

type
  TWhisperSettings = record
    BackendDir: string;      // contains whisper-cli.exe + DLLs (default <exe>\whisper\)
    ModelsDir: string;       // contains *.bin models (default <exe>\models\)
    ModelFile: string;       // selected model basename, e.g. ggml-large-v3-turbo-q5_0.bin
    Language: string;        // '' or e.g. 'ru'
    Enabled: Boolean;
    // Configurable base URLs for downloads
    DllBaseUrl: string;
    ModelBaseUrl: string;
  end;

  TWhisperBackend = (wbNone, wbCPU, wbVulkan, wbCUDA);

  TWhisperResult = record
    Ok: Boolean;
    Text: string;
    ErrorMsg: string;
  end;

  TWhisperCallback = procedure(R: TWhisperResult) of object;

  TWhisperThread = class(TThread)
  private
    FSettings: TWhisperSettings;
    FAudioPath: string;
    FResult: TWhisperResult;
    FCallback: TWhisperCallback;
    FFFmpegPath: string;
    procedure DoCallback;
  protected
    procedure Execute; override;
  public
    constructor Create(const S: TWhisperSettings;
      const AAudio, AFFmpeg: string; ACb: TWhisperCallback);
  end;

function TranscriptPath(const AudioPath: string): string;
function WhisperCliPath(const BackendDir: string): string;
function DetectBackend(const BackendDir: string): TWhisperBackend;
function BackendName(B: TWhisperBackend): string;
function ModelPath(const ModelsDir, ModelFile: string): string;
function TranscribeFileSync(const S: TWhisperSettings;
  const AudioPath, FFmpegPath: string): TWhisperResult;

implementation

function TranscriptPath(const AudioPath: string): string;
begin
  Result := ChangeFileExt(AudioPath, '.txt');
end;

function WhisperCliPath(const BackendDir: string): string;
var
  D: string;
begin
  D := IncludeTrailingPathDelimiter(BackendDir);
  if FileExists(D + 'whisper-cli.exe') then Exit(D + 'whisper-cli.exe');
  if FileExists(D + 'main.exe') then Exit(D + 'main.exe');
  Result := '';
end;

function DetectBackend(const BackendDir: string): TWhisperBackend;
var
  D: string;
begin
  D := IncludeTrailingPathDelimiter(BackendDir);
  if WhisperCliPath(BackendDir) = '' then Exit(wbNone);
  if FileExists(D + 'ggml-cuda.dll') then Exit(wbCUDA);
  if FileExists(D + 'ggml-vulkan.dll') then Exit(wbVulkan);
  Result := wbCPU;
end;

function BackendName(B: TWhisperBackend): string;
begin
  case B of
    wbCPU: Result := 'CPU';
    wbVulkan: Result := 'Vulkan';
    wbCUDA: Result := 'CUDA';
    else Result := 'не установлен';
  end;
end;

function ModelPath(const ModelsDir, ModelFile: string): string;
begin
  if ModelFile = '' then Exit('');
  Result := IncludeTrailingPathDelimiter(ModelsDir) + ModelFile;
end;

// Convert MP3 → 16 kHz mono PCM WAV via ffmpeg. Returns path to temp WAV.
function ConvertToWav(const FFmpegPath, InPath: string;
  out OutPath, ErrorMsg: string): Boolean;
var
  P: TProcess;
  Tmp: string;
  Stderr: AnsiString;
  Buf: array[0..2047] of Byte;
  N: LongInt;
begin
  Result := False;
  OutPath := '';
  ErrorMsg := '';
  Tmp := GetTempDir(False) + 'timerec_' +
         FormatDateTime('yyyymmddhhnnsszzz', Now) + '.wav';
  P := TProcess.Create(nil);
  try
    P.Executable := FFmpegPath;
    P.Parameters.Add('-y');
    P.Parameters.Add('-hide_banner');
    P.Parameters.Add('-nostats');
    P.Parameters.Add('-loglevel'); P.Parameters.Add('error');
    P.Parameters.Add('-i'); P.Parameters.Add(InPath);
    P.Parameters.Add('-ar'); P.Parameters.Add('16000');
    P.Parameters.Add('-ac'); P.Parameters.Add('1');
    P.Parameters.Add('-c:a'); P.Parameters.Add('pcm_s16le');
    P.Parameters.Add(Tmp);
    P.Options := [poUsePipes, poNoConsole, poWaitOnExit];
    try
      P.Execute;
    except
      on E: Exception do
      begin
        ErrorMsg := 'ffmpeg exec: ' + E.Message;
        Exit;
      end;
    end;
    Stderr := '';
    while P.Stderr.NumBytesAvailable > 0 do
    begin
      N := P.Stderr.Read(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetLength(Stderr, Length(Stderr) + N);
        Move(Buf[0], Stderr[Length(Stderr) - N + 1], N);
      end
      else Break;
    end;
    if (P.ExitStatus <> 0) or (not FileExists(Tmp)) then
    begin
      ErrorMsg := 'ffmpeg failed (exit ' + IntToStr(P.ExitStatus) + '): ' +
        Copy(string(Stderr), 1, 500);
      Exit;
    end;
    OutPath := Tmp;
    Result := True;
  finally
    P.Free;
  end;
end;

function TranscribeFileSync(const S: TWhisperSettings;
  const AudioPath, FFmpegPath: string): TWhisperResult;
var
  CliPath, Model, WavPath, OutPrefix, OutTxt: string;
  P: TProcess;
  L: TStringList;
  Err: string;
begin
  Result.Ok := False;
  Result.Text := '';
  Result.ErrorMsg := '';
  CliPath := WhisperCliPath(S.BackendDir);
  if CliPath = '' then
  begin
    Result.ErrorMsg := 'whisper-cli.exe не найден в ' + S.BackendDir;
    Exit;
  end;
  Model := ModelPath(S.ModelsDir, S.ModelFile);
  if (Model = '') or (not FileExists(Model)) then
  begin
    Result.ErrorMsg := 'модель не найдена: ' + Model;
    Exit;
  end;
  if not FileExists(AudioPath) then
  begin
    Result.ErrorMsg := 'аудиофайл не найден: ' + AudioPath;
    Exit;
  end;
  if not ConvertToWav(FFmpegPath, AudioPath, WavPath, Err) then
  begin
    Result.ErrorMsg := Err;
    Exit;
  end;
  try
    OutPrefix := ChangeFileExt(WavPath, '');
    OutTxt := OutPrefix + '.txt';
    P := TProcess.Create(nil);
    try
      P.Executable := CliPath;
      P.Parameters.Add('-m'); P.Parameters.Add(Model);
      P.Parameters.Add('-f'); P.Parameters.Add(WavPath);
      P.Parameters.Add('-otxt');
      P.Parameters.Add('-of'); P.Parameters.Add(OutPrefix);
      P.Parameters.Add('-nt');  // no timestamps in output
      if S.Language <> '' then
      begin
        P.Parameters.Add('-l'); P.Parameters.Add(S.Language);
      end
      else
      begin
        P.Parameters.Add('-l'); P.Parameters.Add('auto');
      end;
      P.Options := [poUsePipes, poNoConsole, poWaitOnExit];
      try
        P.Execute;
      except
        on E: Exception do
        begin
          Result.ErrorMsg := 'whisper exec: ' + E.Message;
          Exit;
        end;
      end;
      if P.ExitStatus <> 0 then
      begin
        Result.ErrorMsg := 'whisper-cli exit ' + IntToStr(P.ExitStatus);
        Exit;
      end;
    finally
      P.Free;
    end;
    if not FileExists(OutTxt) then
    begin
      Result.ErrorMsg := 'whisper не создал текстовый файл';
      Exit;
    end;
    L := TStringList.Create;
    try
      L.LoadFromFile(OutTxt);
      Result.Text := Trim(L.Text);
      Result.Ok := Result.Text <> '';
      if not Result.Ok then Result.ErrorMsg := 'пустой результат';
    finally
      L.Free;
    end;
    SysUtils.DeleteFile(OutTxt);
  finally
    if FileExists(WavPath) then SysUtils.DeleteFile(WavPath);
  end;
end;

{ TWhisperThread }

constructor TWhisperThread.Create(const S: TWhisperSettings;
  const AAudio, AFFmpeg: string; ACb: TWhisperCallback);
begin
  FSettings := S;
  FAudioPath := AAudio;
  FFFmpegPath := AFFmpeg;
  FCallback := ACb;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TWhisperThread.Execute;
begin
  try
    FResult := TranscribeFileSync(FSettings, FAudioPath, FFFmpegPath);
  except
    on E: Exception do
    begin
      FResult.Ok := False;
      FResult.ErrorMsg := E.ClassName + ': ' + E.Message;
    end;
  end;
  if Assigned(FCallback) then Synchronize(@DoCallback);
end;

procedure TWhisperThread.DoCallback;
begin
  FCallback(FResult);
end;

end.
