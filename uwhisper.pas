unit uwhisper;

// Local Whisper transcription via the whisper.cpp CLI binary
// (whisper-cli.exe, formerly main.exe). User installs the whisper.cpp
// release ZIP into a "whisper" subfolder via the settings dialog; we
// look it up at runtime. MP3 is decoded to PCM WAV via the bundled
// ffmpeg.exe before invocation.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, Pipes, StrUtils, Windows;

type
  TWhisperSettings = record
    BackendDir: string;      // contains whisper-cli.exe + DLLs (default <exe>\whisper\)
    ModelsDir: string;       // contains *.bin models (default <exe>\models\)
    ModelFile: string;       // selected model basename, e.g. ggml-large-v3-turbo-q5_0.bin
    Language: string;        // '' or e.g. 'ru'
    Enabled: Boolean;
    ShowTimestamps: Boolean; // include per-segment [MM:SS.mmm --> ...] in output
    // Configurable base URLs for downloads
    DllBaseUrl: string;
    ModelBaseUrl: string;
  end;

  TWhisperBackend = (wbNone, wbCPU, wbBLAS, wbCUDA, wbVulkan);

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
function ScrubHallucinations(const Text: string): string;
procedure SetLogPath(const Path: string);
procedure WhisperLog(const Msg: string);
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

function ScrubHallucinations(const Text: string): string;
// Whisper галлюцинирует на тишине/шуме/музыке — выдаёт фразы из
// обучения на YouTube-сабах. Чистим в два прохода:
//  1) построчно — целая строка с известной фразой выбрасывается
//     (это важно для режима с таймштампами — там каждая строка
//     соответствует одному сегменту);
//  2) внутри обычных строк — режем на предложения по .!? и выкидываем
//     предложения с джанк-подстроками. Строки, начинающиеся с '['
//     (таймштамп), не режем — иначе временные точки сломаются.
const
  Junk: array[0..21] of string = (
    'DimaTorzok',
    'Дима Торжок',
    'Субтитры сделал',
    'Субтитры создавал',
    'Субтитры подогнал',
    'Субтитры подготовил',
    'Субтитры от',
    'Редактор субтитров',
    'Корректор А.',
    'Поставьте лайк',
    'Подпишитесь на канал',
    'Подписывайтесь на канал',
    'Продолжение следует',
    'Спасибо за внимание',
    'Спасибо за просмотр',
    'Thanks for watching',
    'Thank you for watching',
    'Please subscribe',
    'Like and subscribe',
    'Subtitles by',
    'Amara.org',
    'Don''t forget to subscribe'
  );

  function HasJunk(const S: string): Boolean;
  var
    k: Integer;
    L: string;
  begin
    L := LowerCase(S);
    for k := 0 to High(Junk) do
      if Pos(LowerCase(Junk[k]), L) > 0 then Exit(True);
    Result := False;
  end;

  function ScrubSentences(const S: string): string;
  var
    i, n, last: Integer;
    Piece: string;
    Sep: Char;

    procedure Emit(const P: string);
    var T: string;
    begin
      T := Trim(P);
      if T = '' then Exit;
      if HasJunk(T) then
      begin
        WhisperLog('  scrub: "' + T + '"');
        Exit;
      end;
      if Result <> '' then Result := Result + ' ';
      Result := Result + T;
    end;

  begin
    Result := '';
    last := 1;
    i := 1;
    n := Length(S);
    while i <= n do
    begin
      Sep := S[i];
      if (Sep = '.') or (Sep = '!') or (Sep = '?') then
      begin
        Emit(Copy(S, last, i - last + 1));
        Inc(i);
        while (i <= n) and (S[i] = ' ') do Inc(i);
        last := i;
      end
      else
        Inc(i);
    end;
    if last <= n then Emit(Copy(S, last, n - last + 1));
  end;

var
  Lines: TStringList;
  i: Integer;
  Cleaned, Line: string;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if Line = '' then Continue;
      if Line[1] = '[' then
      begin
        // Timestamp line — atomic: either keep or drop.
        if HasJunk(Line) then
        begin
          WhisperLog('  scrub line: "' + Line + '"');
          Continue;
        end;
        if Result <> '' then Result := Result + LineEnding;
        Result := Result + Line;
      end
      else
      begin
        Cleaned := ScrubSentences(Line);
        if Cleaned <> '' then
        begin
          if Result <> '' then Result := Result + LineEnding;
          Result := Result + Cleaned;
        end;
      end;
    end;
  finally
    Lines.Free;
  end;
end;

var
  GLogPath: string = '';

procedure SetLogPath(const Path: string);
begin
  GLogPath := Path;
end;

procedure WhisperLog(const Msg: string);
var
  H: THandle;
  Line: AnsiString;
begin
  if GLogPath = '' then Exit;
  if FileExists(GLogPath) then H := FileOpen(GLogPath, fmOpenWrite or fmShareDenyNone)
  else H := FileCreate(GLogPath);
  if H = THandle(-1) then Exit;
  try
    FileSeek(H, 0, soFromEnd);
    Line := AnsiString(FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now) +
      ' ' + Msg + #13#10);
    FileWrite(H, Line[1], Length(Line));
  finally
    FileClose(H);
  end;
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
  if FileExists(D + 'openblas.dll') or
     FileExists(D + 'libopenblas.dll') then Exit(wbBLAS);
  Result := wbCPU;
end;

function BackendName(B: TWhisperBackend): string;
begin
  case B of
    wbCPU: Result := 'CPU';
    wbBLAS: Result := 'CPU + BLAS';
    wbCUDA: Result := 'CUDA';
    wbVulkan: Result := 'Vulkan (пользовательская сборка)';
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

function DrainStream(Stream: TInputPipeStream): string;
var
  Buf: array[0..4095] of Byte;
  N: LongInt;
  S: AnsiString;
begin
  Result := '';
  if Stream = nil then Exit;
  S := '';
  while Stream.NumBytesAvailable > 0 do
  begin
    N := Stream.Read(Buf, SizeOf(Buf));
    if N > 0 then
    begin
      SetLength(S, Length(S) + N);
      Move(Buf[0], S[Length(S) - N + 1], N);
    end
    else Break;
  end;
  Result := string(S);
end;

function CaptureStderr(P: TProcess): string;
begin
  Result := DrainStream(P.Stderr);
end;

function ParseCsvLine(const Line: string; out StartMs, EndMs: Int64;
  out TextOut: string): Boolean;
var
  c1, c2: Integer;
begin
  Result := False;
  c1 := Pos(',', Line);
  if c1 = 0 then Exit;
  c2 := PosEx(',', Line, c1 + 1);
  if c2 = 0 then Exit;
  if not TryStrToInt64(Copy(Line, 1, c1 - 1), StartMs) then Exit;
  if not TryStrToInt64(Copy(Line, c1 + 1, c2 - c1 - 1), EndMs) then Exit;
  TextOut := Copy(Line, c2 + 1, MaxInt);
  if (Length(TextOut) >= 2) and (TextOut[1] = '"') and
     (TextOut[Length(TextOut)] = '"') then
    TextOut := Copy(TextOut, 2, Length(TextOut) - 2);
  TextOut := StringReplace(TextOut, '""', '"', [rfReplaceAll]);
  TextOut := Trim(TextOut);
  Result := True;
end;

function FormatBracket(StartMs, EndMs: Int64): string;
  function F(Ms: Int64): string;
  var H, M, Sec, MM: Int64;
  begin
    H := Ms div 3600000;
    M := (Ms div 60000) mod 60;
    Sec := (Ms div 1000) mod 60;
    MM := Ms mod 1000;
    Result := Format('%.2d:%.2d:%.2d.%.3d', [H, M, Sec, MM]);
  end;
begin
  Result := '[' + F(StartMs) + ' --> ' + F(EndMs) + ']';
end;

function CsvFileToBracketedText(const CsvPath: string): string;
var
  L: TStringList;
  i: Integer;
  StartMs, EndMs: Int64;
  Body: string;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.LoadFromFile(CsvPath);
    for i := 0 to L.Count - 1 do
    begin
      if (i = 0) and (Pos('start,end,text', L[i]) > 0) then Continue;
      if Trim(L[i]) = '' then Continue;
      if not ParseCsvLine(L[i], StartMs, EndMs, Body) then Continue;
      if Body = '' then Continue;
      if Result <> '' then Result := Result + LineEnding;
      Result := Result + FormatBracket(StartMs, EndMs) + '   ' + Body;
    end;
  finally
    L.Free;
  end;
end;

function TranscribeFileSync(const S: TWhisperSettings;
  const AudioPath, FFmpegPath: string): TWhisperResult;
var
  CliPath, Model, OutPrefix, OutCsv, Stderr, CmdEcho: string;
  P: TProcess;
  TStart: QWord;
  i: Integer;
begin
  Result.Ok := False;
  Result.Text := '';
  Result.ErrorMsg := '';
  WhisperLog('--- TranscribeFileSync ---');
  WhisperLog('  audio: ' + AudioPath);
  WhisperLog('  backend dir: ' + S.BackendDir);
  WhisperLog('  models dir: ' + S.ModelsDir);
  WhisperLog('  model: ' + S.ModelFile);
  WhisperLog('  language: ' + S.Language);
  CliPath := WhisperCliPath(S.BackendDir);
  if CliPath = '' then
  begin
    Result.ErrorMsg := 'whisper-cli.exe не найден в ' + S.BackendDir;
    WhisperLog('ERROR: ' + Result.ErrorMsg);
    Exit;
  end;
  WhisperLog('  cli: ' + CliPath);
  Model := ModelPath(S.ModelsDir, S.ModelFile);
  if (Model = '') or (not FileExists(Model)) then
  begin
    Result.ErrorMsg := 'модель не найдена: ' + Model;
    WhisperLog('ERROR: ' + Result.ErrorMsg);
    Exit;
  end;
  if not FileExists(AudioPath) then
  begin
    Result.ErrorMsg := 'аудиофайл не найден: ' + AudioPath;
    WhisperLog('ERROR: ' + Result.ErrorMsg);
    Exit;
  end;
  // whisper-cli reads MP3 / WAV / FLAC / OGG natively — no conversion
  // needed. We avoid round-tripping through ffmpeg (the minimal build
  // we ship doesn't include the wav muxer anyway).
  OutPrefix := IncludeTrailingPathDelimiter(GetTempDir(False)) +
    'timerec_whisper_' + FormatDateTime('yyyymmddhhnnsszzz', Now);
  OutCsv := OutPrefix + '.csv';
  TStart := GetTickCount64;
  P := TProcess.Create(nil);
  try
    try
      P.Executable := CliPath;
      P.Parameters.Add('-m'); P.Parameters.Add(Model);
      P.Parameters.Add('-f'); P.Parameters.Add(AudioPath);
      // CSV output is the only format that always carries timestamps in
      // the file (the -otxt path strips them even without -nt). We
      // convert to our bracketed text format ourselves below.
      P.Parameters.Add('-ocsv');
      P.Parameters.Add('-of'); P.Parameters.Add(OutPrefix);
      // Force shorter segments so the viewer's row-highlight updates
      // more often and per-row timestamps drift less.
      P.Parameters.Add('-ml'); P.Parameters.Add('70');
      P.Parameters.Add('-sow');
      if S.Language <> '' then
      begin
        P.Parameters.Add('-l'); P.Parameters.Add(S.Language);
      end
      else
      begin
        P.Parameters.Add('-l'); P.Parameters.Add('auto');
      end;
      // poWaitOnExit is intentionally NOT set — we must drain stderr in
      // parallel with the running process, otherwise whisper-cli's
      // pipe back-pressures the writer and the process hangs (we saw
      // this in the wild: 0.08 s CPU after 7 minutes).
      P.Options := [poUsePipes, poNoConsole];
      CmdEcho := P.Executable;
      for i := 0 to P.Parameters.Count - 1 do
        CmdEcho := CmdEcho + ' "' + P.Parameters[i] + '"';
      WhisperLog('  cmd: ' + CmdEcho);
      try
        P.Execute;
      except
        on E: Exception do
        begin
          Result.ErrorMsg := 'whisper exec: ' + E.Message;
          WhisperLog('ERROR: ' + Result.ErrorMsg);
          Exit;
        end;
      end;
      Stderr := '';
      while P.Running do
      begin
        Stderr := Stderr + DrainStream(P.Stderr);
        DrainStream(P.Output);  // discard stdout; we read text from .txt
        Sleep(50);
      end;
      // Final drain after process exits
      Stderr := Stderr + DrainStream(P.Stderr);
      DrainStream(P.Output);
      WhisperLog('  exit: ' + IntToStr(P.ExitStatus) +
        '  took: ' + IntToStr(GetTickCount64 - TStart) + ' ms');
      if Stderr <> '' then
        WhisperLog('  stderr: ' + Copy(Stderr, 1, 4000));
      if P.ExitStatus <> 0 then
      begin
        Result.ErrorMsg := 'whisper-cli exit ' + IntToStr(P.ExitStatus) +
          ': ' + Copy(Stderr, 1, 500);
        Exit;
      end;
    finally
      P.Free;
    end;
    if not FileExists(OutCsv) then
    begin
      Result.ErrorMsg := 'whisper не создал CSV-файл';
      WhisperLog('ERROR: ' + Result.ErrorMsg);
      Exit;
    end;
    Result.Text := CsvFileToBracketedText(OutCsv);
    WhisperLog('  raw length: ' + IntToStr(Length(Result.Text)));
    Result.Text := ScrubHallucinations(Result.Text);
    WhisperLog('  scrubbed length: ' + IntToStr(Length(Result.Text)));
    Result.Ok := Result.Text <> '';
    if not Result.Ok then Result.ErrorMsg := 'пустой результат';
    SysUtils.DeleteFile(OutCsv);
  finally
    if FileExists(OutCsv) then SysUtils.DeleteFile(OutCsv);
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
