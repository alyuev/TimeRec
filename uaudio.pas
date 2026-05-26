unit uaudio;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, Windows, syncobjs, uwasapiloop;

function Min(A, B: LongInt): LongInt; inline;

type
  TAudioQuality = (aqLow, aqMid, aqHigh);

  TStderrDrainThread = class;

  TAudioRecorder = class
  private
    FProcess: TProcess;
    FOutputFile: string;
    FStartTime: TDateTime;
    FAppDir: string;
    FLoop: TWasapiLoopback;
    FMic: TWasapiLoopback;  // optional WASAPI mic capture (faster than dshow)
    FMicPipeHandle: THandle;
    FMicPipeName: string;
    FMicPipeBroken: Boolean;
    FWriteLock: TCriticalSection;
    FPipeBroken: Boolean;
    FDrain: TStderrDrainThread;
    FLogPath: string;
    FPipeHandle: THandle;
    FPipeName: string;
    FCurrentRmsDb: Double;
    FVadThresholdDb: Double;
    FVadSilent: Boolean;
    FNeedTrimPostPass: Boolean;
    FTrimThresholdDb: Double;
    FCachedFloorDb: Double;
    FLastFloorDb: Double;
  public
    FVadSensitivity: Integer;  // -10..+10 dB bias added to calibrated threshold
    function CurrentRmsDb: Double;
    function VadThresholdDb: Double;
    function VadIsSilent: Boolean;
    // Caller may pre-seed the noise floor (from config) so Start skips
    // the 1.5 s calibration probe. -999 means "no cache, calibrate".
    procedure SetCachedFloorDb(Value: Double);
    // After Start, the floor that was used (whether cached or freshly
    // measured). Caller saves this to config for next time.
    function LastFloorDb: Double;
  private
    function FindFFmpeg: string;
    procedure OnLoopData(Data: Pointer; Bytes: Integer);
    procedure AppendLog(const S: string);
    function CreateLoopbackPipe: Boolean;
    procedure ClosePipe;
    procedure AcceptLoopbackConnection;
    procedure TrimSilencePostPass;
    function CreateMicPipe: Boolean;
    procedure CloseMicPipe;
    procedure AcceptMicConnection;
    procedure OnMicData(Data: Pointer; Bytes: Integer);
  public
    function CalibrateMicNoiseFloorDb(const MicDevice: string): Double;
  private
  public
    constructor Create(const AAppDir: string);
    destructor Destroy; override;
    function Start(const OutFile: string; Mic, Sys: Boolean;
      Quality: TAudioQuality; const MicDevice: string;
      AutoPauseOnSilence: Boolean = False): Boolean;
    procedure Stop;
    function IsRecording: Boolean;
    function CurrentFile: string;
    function ElapsedSec: Int64;
    function FFmpegAvailable: Boolean;
    function DetectFirstMic: string;
    procedure ListMics(AOut: TStrings);
  end;

  TStderrDrainThread = class(TThread)
  private
    FOwner: TAudioRecorder;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TAudioRecorder);
  end;

const
  QualityBitrate: array[TAudioQuality] of Integer = (64, 128, 256);

implementation

uses
  DateUtils, StrUtils;

function Min(A, B: LongInt): LongInt;
begin
  if A < B then Result := A else Result := B;
end;

constructor TAudioRecorder.Create(const AAppDir: string);
begin
  inherited Create;
  FAppDir := AAppDir;
  FProcess := nil;
  FWriteLock := TCriticalSection.Create;
  FLogPath := IncludeTrailingPathDelimiter(FAppDir) + 'ffmpeg_audio.log';
  FPipeHandle := INVALID_HANDLE_VALUE;
  FCurrentRmsDb := -100;
  FVadThresholdDb := -32;
  FCachedFloorDb := -999;
  FLastFloorDb := -999;
  FMicPipeHandle := INVALID_HANDLE_VALUE;
end;

function TAudioRecorder.CurrentRmsDb: Double;
begin
  Result := FCurrentRmsDb;
end;

function TAudioRecorder.VadThresholdDb: Double;
begin
  Result := FVadThresholdDb;
end;

function TAudioRecorder.VadIsSilent: Boolean;
begin
  Result := FVadSilent;
end;

procedure TAudioRecorder.SetCachedFloorDb(Value: Double);
begin
  FCachedFloorDb := Value;
end;

function TAudioRecorder.LastFloorDb: Double;
begin
  Result := FLastFloorDb;
end;

procedure TAudioRecorder.AppendLog(const S: string);
var
  H: THandle;
  Line: AnsiString;
begin
  if FLogPath = '' then Exit;
  if FileExists(FLogPath) then H := FileOpen(FLogPath, fmOpenWrite or fmShareDenyNone)
  else H := FileCreate(FLogPath);
  if H = THandle(-1) then Exit;
  try
    FileSeek(H, 0, soFromEnd);
    Line := FormatDateTime('hh:nn:ss.zzz', Now) + ' ' + S + #13#10;
    FileWrite(H, Line[1], Length(Line));
  finally
    FileClose(H);
  end;
end;

constructor TStderrDrainThread.Create(AOwner: TAudioRecorder);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TStderrDrainThread.Execute;
var
  Buf: array[0..2047] of Byte;
  N, i, LineStart: LongInt;
  S, Line, Frag, Tail: AnsiString;
  V: Double;
  Fmt: TFormatSettings;
  HasErr: Boolean;
begin
  Frag := '';
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';
  while not Terminated do
  begin
    if (FOwner.FProcess = nil) or (not FOwner.FProcess.Running) then Exit;
    if FOwner.FProcess.Stderr.NumBytesAvailable > 0 then
    begin
      N := FOwner.FProcess.Stderr.Read(Buf,
        Min(SizeOf(Buf), FOwner.FProcess.Stderr.NumBytesAvailable));
      if N > 0 then
      begin
        SetLength(S, N); Move(Buf[0], S[1], N);
        Frag := Frag + S;
        // Split on \n, parse each complete line.
        LineStart := 1;
        for i := 1 to Length(Frag) do
          if Frag[i] = #10 then
          begin
            Line := Copy(Frag, LineStart, i - LineStart);
            LineStart := i + 1;
            HasErr := False;
            if PosEx('silence_start', Line, 1) > 0 then
            begin
              FOwner.FVadSilent := True;
              FOwner.AppendLog('[ffmpeg] ' + Line);
            end
            else if PosEx('silence_end', Line, 1) > 0 then
            begin
              FOwner.FVadSilent := False;
              FOwner.AppendLog('[ffmpeg] ' + Line);
            end
            else
            begin
              N := PosEx('RMS_level=', Line, 1);
              if N > 0 then
              begin
                Tail := Copy(Line, N + Length('RMS_level='), MaxInt);
                if (Tail = '-inf') or (Copy(Tail, 1, 4) = '-inf') then
                  FOwner.FCurrentRmsDb := -100
                else if TryStrToFloat(Trim(Tail), V, Fmt) then
                  FOwner.FCurrentRmsDb := V;
              end
              else
                HasErr := Length(Line) > 0;
            end;
            if HasErr then FOwner.AppendLog('[ffmpeg] ' + Line);
          end;
        if LineStart > 1 then Frag := Copy(Frag, LineStart, MaxInt);
      end;
    end
    else
      Sleep(30);
  end;
end;

destructor TAudioRecorder.Destroy;
begin
  if IsRecording then Stop;
  FWriteLock.Free;
  inherited;
end;

procedure TAudioRecorder.OnLoopData(Data: Pointer; Bytes: Integer);
var
  Written: DWORD;
begin
  if FPipeBroken or (FPipeHandle = INVALID_HANDLE_VALUE) or
     (Data = nil) or (Bytes <= 0) then Exit;
  FWriteLock.Enter;
  try
    if FPipeHandle = INVALID_HANDLE_VALUE then Exit;
    if not WriteFile(FPipeHandle, Data^, Bytes, Written, nil) then
      FPipeBroken := True;
  finally
    FWriteLock.Leave;
  end;
end;

procedure TAudioRecorder.OnMicData(Data: Pointer; Bytes: Integer);
var
  Written: DWORD;
begin
  if FMicPipeBroken or (FMicPipeHandle = INVALID_HANDLE_VALUE) or
     (Data = nil) or (Bytes <= 0) then Exit;
  if not WriteFile(FMicPipeHandle, Data^, Bytes, Written, nil) then
    FMicPipeBroken := True;
end;


function TAudioRecorder.CalibrateMicNoiseFloorDb(const MicDevice: string): Double;
// Probes the mic for 1.5 s, collects per-frame RMS_level via astats,
// returns the 20th percentile — robust against transient noise (e.g.
// the user being momentarily noisy during the probe window).
var
  P: TProcess;
  Buf: array[0..2047] of Byte;
  S, Line, Tail: AnsiString;
  N, i, j, k, pStart, pEnd, Waited: Integer;
  V, Tmp: Double;
  FmtDot: TFormatSettings;
  Rms: array of Double;
begin
  Result := -999;
  if not FFmpegAvailable then Exit;
  SetLength(Rms, 0);
  FmtDot := DefaultFormatSettings;
  FmtDot.DecimalSeparator := '.';

  P := TProcess.Create(nil);
  try
    P.Executable := FindFFmpeg;
    P.Parameters.Add('-y');
    P.Parameters.Add('-hide_banner');
    P.Parameters.Add('-nostats');
    P.Parameters.Add('-loglevel'); P.Parameters.Add('info');
    P.Parameters.Add('-f'); P.Parameters.Add('dshow');
    P.Parameters.Add('-rtbufsize'); P.Parameters.Add('16M');
    P.Parameters.Add('-i'); P.Parameters.Add('audio=' + MicDevice);
    P.Parameters.Add('-t'); P.Parameters.Add('1.5');
    P.Parameters.Add('-af');
    P.Parameters.Add('astats=metadata=1:reset=1,' +
                     'ametadata=print:key=lavfi.astats.Overall.RMS_level');
    P.Parameters.Add('-f'); P.Parameters.Add('null');
    P.Parameters.Add('-');
    P.Options := [poUsePipes, poNoConsole];
    S := '';
    try
      P.Execute;
      Waited := 0;
      while (Waited < 6000) and (P.Running or (P.Stderr.NumBytesAvailable > 0)) do
      begin
        if P.Stderr.NumBytesAvailable > 0 then
        begin
          N := P.Stderr.Read(Buf, Min(SizeOf(Buf), P.Stderr.NumBytesAvailable));
          if N > 0 then
          begin
            SetLength(Line, N); Move(Buf[0], Line[1], N);
            S := S + Line;
          end;
        end
        else
        begin
          Sleep(40); Inc(Waited, 40);
        end;
      end;
      if P.Running then try P.Terminate(0); except end;
    except
    end;

    pStart := 1;
    while pStart <= Length(S) do
    begin
      pEnd := pStart;
      while (pEnd <= Length(S)) and (S[pEnd] <> #10) do Inc(pEnd);
      Line := Copy(S, pStart, pEnd - pStart);
      i := PosEx('RMS_level=', Line, 1);
      if i > 0 then
      begin
        Tail := Copy(Line, i + Length('RMS_level='), MaxInt);
        N := 1;
        while (N <= Length(Tail)) and ((Tail[N] = '-') or (Tail[N] = '.') or
              (Tail[N] = 'i') or (Tail[N] = 'n') or (Tail[N] = 'f') or
              ((Tail[N] >= '0') and (Tail[N] <= '9'))) do Inc(N);
        Tail := Copy(Tail, 1, N - 1);
        if (Tail <> '-inf') and (Tail <> 'inf') and (Tail <> '') and
           TryStrToFloat(Tail, V, FmtDot) then
        begin
          SetLength(Rms, Length(Rms) + 1);
          Rms[High(Rms)] := V;
        end;
      end;
      pStart := pEnd + 1;
    end;
  finally
    P.Free;
  end;

  if Length(Rms) = 0 then Exit;
  for j := 0 to High(Rms) - 1 do
    for k := j + 1 to High(Rms) do
      if Rms[k] < Rms[j] then
      begin
        Tmp := Rms[j]; Rms[j] := Rms[k]; Rms[k] := Tmp;
      end;
  i := Length(Rms) div 5;  // 20th percentile
  Result := Rms[i];
  AppendLog(Format('Calibration: %d samples min=%.1f p20=%.1f med=%.1f max=%.1f',
    [Length(Rms), Rms[0], Result, Rms[Length(Rms) div 2], Rms[High(Rms)]]));
end;

function FileSize2(const P: string): Int64;
var FS: TFileStream;
begin
  Result := 0;
  if not FileExists(P) then Exit;
  try
    FS := TFileStream.Create(P, fmOpenRead or fmShareDenyNone);
    try Result := FS.Size finally FS.Free end;
  except end;
end;

procedure TAudioRecorder.TrimSilencePostPass;
// After recording is stopped, re-encode the file with silenceremove
// to trim leading/trailing/inter silences. The live recording graph
// can't apply silenceremove without stalling the filter scheduler.
var
  P: TProcess;
  TmpPath, ThrStr: string;
  i: Integer;
begin
  if not FNeedTrimPostPass then Exit;
  if not FileExists(FOutputFile) then Exit;
  TmpPath := FOutputFile + '.trim.mp3';
  ThrStr := StringReplace(FloatToStrF(FTrimThresholdDb, ffFixed, 5, 1),
                          ',', '.', []);
  AppendLog(Format('Post-trim: %s with threshold %s dB', [FOutputFile, ThrStr]));
  P := TProcess.Create(nil);
  try
    P.Executable := FindFFmpeg;
    P.Parameters.Add('-y');
    P.Parameters.Add('-hide_banner');
    P.Parameters.Add('-nostats');
    P.Parameters.Add('-loglevel'); P.Parameters.Add('error');
    P.Parameters.Add('-i'); P.Parameters.Add(FOutputFile);
    P.Parameters.Add('-af');
    P.Parameters.Add(
      'silenceremove=start_periods=1:start_duration=0.05:start_threshold=' +
      ThrStr + 'dB:stop_periods=-1:stop_duration=0.7:stop_threshold=' +
      ThrStr + 'dB:detection=rms:window=0.4,asetpts=N/SR/TB');
    P.Parameters.Add('-c:a'); P.Parameters.Add('libmp3lame');
    P.Parameters.Add('-q:a'); P.Parameters.Add('5');
    P.Parameters.Add(TmpPath);
    P.Options := [poUsePipes, poNoConsole];
    try
      P.Execute;
      // Wait up to 15s (file can be several MB).
      for i := 1 to 150 do
      begin
        if not P.Running then Break;
        Sleep(100);
      end;
      if P.Running then
        try P.Terminate(0); except end;
    except
      on E: Exception do
        AppendLog('Post-trim exception: ' + E.Message);
    end;
  finally
    P.Free;
  end;
  if FileExists(TmpPath) and (FileSize2(TmpPath) > 256) then
  begin
    try SysUtils.DeleteFile(FOutputFile); except end;
    if not RenameFile(TmpPath, FOutputFile) then
      AppendLog('Post-trim: rename failed');
  end
  else
    AppendLog('Post-trim produced no usable output, keeping original');
end;

function TAudioRecorder.CreateLoopbackPipe: Boolean;
const
  PIPE_ACCESS_OUTBOUND = $00000002;
  PIPE_TYPE_BYTE = 0;
  PIPE_WAIT = 0;
  PIPE_REJECT_REMOTE_CLIENTS = 8;
begin
  Result := False;
  FPipeName := '\\.\pipe\timerec_' + IntToStr(GetCurrentProcessId) + '_' +
               IntToStr(GetTickCount64);
  FPipeHandle := CreateNamedPipeA(PAnsiChar(AnsiString(FPipeName)),
    PIPE_ACCESS_OUTBOUND,
    PIPE_TYPE_BYTE or PIPE_WAIT or PIPE_REJECT_REMOTE_CLIENTS,
    1, 2*1024*1024, 0, 0, nil);
  if FPipeHandle = INVALID_HANDLE_VALUE then
  begin
    AppendLog('CreateNamedPipe failed: ' + IntToStr(GetLastError));
    Exit;
  end;
  Result := True;
end;

type
  TPipeConnectThread = class(TThread)
  private
    FHandle: THandle;
    FConnected: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AHandle: THandle);
    property Connected: Boolean read FConnected;
  end;

constructor TPipeConnectThread.Create(AHandle: THandle);
begin
  FHandle := AHandle;
  FConnected := False;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TPipeConnectThread.Execute;
const
  ERROR_PIPE_CONNECTED = 535;
var
  Ok: BOOL;
begin
  Ok := ConnectNamedPipe(FHandle, nil);
  FConnected := Ok or (GetLastError = ERROR_PIPE_CONNECTED);
end;

procedure TAudioRecorder.ClosePipe;
begin
  if FPipeHandle <> INVALID_HANDLE_VALUE then
  begin
    try FlushFileBuffers(FPipeHandle); except end;
    try CloseHandle(FPipeHandle); except end;
    FPipeHandle := INVALID_HANDLE_VALUE;
  end;
end;

function TAudioRecorder.FindFFmpeg: string;
var
  P: string;
begin
  // 1. Same directory as the app
  P := IncludeTrailingPathDelimiter(FAppDir) + 'ffmpeg.exe';
  if FileExists(P) then Exit(P);
  // 2. Rely on PATH lookup (FPC's TProcess can resolve unqualified
  //    names on Windows when no path separator is present).
  Result := 'ffmpeg.exe';
end;

procedure TAudioRecorder.ListMics(AOut: TStrings);
var
  P: TProcess;
  S: TMemoryStream;
  Buf: array[0..2047] of Byte;
  N: LongInt;
  Total: TStringList;
  Line, Curr: string;
  i, q1, q2: Integer;
begin
  AOut.Clear;
  if not FFmpegAvailable then Exit;
  P := TProcess.Create(nil);
  S := TMemoryStream.Create;
  Total := TStringList.Create;
  try
    P.Executable := FindFFmpeg;
    P.Parameters.Add('-hide_banner');
    P.Parameters.Add('-list_devices'); P.Parameters.Add('true');
    P.Parameters.Add('-f'); P.Parameters.Add('dshow');
    P.Parameters.Add('-i'); P.Parameters.Add('dummy');
    P.Options := [poUsePipes, poNoConsole];
    try
      P.Execute;
      while True do
      begin
        Sleep(30);
        if P.Stderr.NumBytesAvailable > 0 then
        begin
          N := P.Stderr.Read(Buf, Min(SizeOf(Buf), P.Stderr.NumBytesAvailable));
          if N > 0 then S.WriteBuffer(Buf, N);
        end
        else if not P.Running then Break;
      end;
      while P.Stderr.NumBytesAvailable > 0 do
      begin
        N := P.Stderr.Read(Buf, Min(SizeOf(Buf), P.Stderr.NumBytesAvailable));
        if N > 0 then S.WriteBuffer(Buf, N);
      end;
      S.Position := 0;
      Total.LoadFromStream(S);
      for i := 0 to Total.Count - 1 do
      begin
        Line := Total[i];
        if Pos('(audio)', Line) > 0 then
        begin
          q1 := Pos('"', Line);
          if q1 > 0 then
          begin
            q2 := Pos('"', Line, q1 + 1);
            if q2 > q1 then
            begin
              Curr := Copy(Line, q1 + 1, q2 - q1 - 1);
              if (Curr <> '') and (AOut.IndexOf(Curr) < 0) then
                AOut.Add(Curr);
            end;
          end;
        end;
      end;
    except
    end;
  finally
    Total.Free;
    S.Free;
    P.Free;
  end;
end;

function TAudioRecorder.DetectFirstMic: string;
var
  L: TStringList;
begin
  Result := '';
  L := TStringList.Create;
  try
    ListMics(L);
    if L.Count > 0 then Result := L[0];
  finally
    L.Free;
  end;
end;

function TAudioRecorder.FFmpegAvailable: Boolean;
var
  Path: string;
begin
  // Don't spawn `ffmpeg -version` — with pipes attached and no drainer
  // it deadlocks (ffmpeg blocks on its stdout, WaitOnExit blocks here).
  // Just check the local copy; if the user has it in PATH only, our
  // FindFFmpeg returns the bare name and the actual Start call will
  // surface any "not found" error.
  Path := IncludeTrailingPathDelimiter(FAppDir) + 'ffmpeg.exe';
  Result := FileExists(Path);
end;

function TAudioRecorder.Start(const OutFile: string; Mic, Sys: Boolean;
  Quality: TAudioQuality; const MicDevice: string;
  AutoPauseOnSilence: Boolean): Boolean;
var
  Bitrate, InputCount, SysIdx, MicIdx: Integer;
  ActualMic, SysFmt, SilenceChain, GraphPre, SilenceDetect: string;
  NoiseFloorDb, ThresholdDb: Double;
  TStart, TPrev, TNow: QWord;
  procedure TimePoint(const What: string);
  begin
    TNow := GetTickCount64;
    AppendLog(Format('  +%4d ms (Δ%4d) %s',
      [TNow - TStart, TNow - TPrev, What]));
    TPrev := TNow;
  end;
begin
  TStart := GetTickCount64; TPrev := TStart;
  Result := False;
  if IsRecording then Exit;
  if not (Mic or Sys) then Exit;

  FOutputFile := OutFile;
  ForceDirectories(ExtractFilePath(OutFile));
  FPipeBroken := False;

  Bitrate := QualityBitrate[Quality];
  ActualMic := MicDevice;
  if ActualMic = '' then ActualMic := 'Microphone';
  // ListMics returns UTF-8 (ffmpeg writes stderr in UTF-8). FPC's
  // TProcess on Windows builds the WCHAR command line via the string's
  // codepage; if our UTF-8 bytes are tagged with the default ANSI
  // codepage they get mistranslated. Round-trip through UnicodeString
  // produces an AnsiString in DefaultSystemCodePage that TProcess will
  // convert back to UTF-16 correctly.
  ActualMic := AnsiString(UTF8Decode(ActualMic));

  // If system audio is requested, start WASAPI loopback first so we
  // know the device's native PCM format to declare to ffmpeg. Note:
  // OnData is left nil for now — we wire it AFTER ffmpeg has connected
  // to the named pipe. Otherwise WriteFile blocks on the unconnected
  // pipe, the WASAPI thread stalls, and Windows drops the initial
  // packets, producing a ragged opening few seconds in the recording.
  TimePoint('enter');
  if Sys then
  begin
    if not CreateLoopbackPipe then Exit;
    TimePoint('sys pipe created');
    FLoop := TWasapiLoopback.Create;
    FLoop.OnData := nil;
    if not FLoop.Start then
    begin
      FreeAndNil(FLoop);
      ClosePipe;
      Exit;
    end;
    TimePoint('sys WASAPI loopback started');
  end;

  FProcess := TProcess.Create(nil);
  FProcess.Executable := FindFFmpeg;
  FProcess.Parameters.Add('-y');
  FProcess.Parameters.Add('-hide_banner');
  FProcess.Parameters.Add('-nostats');
  FProcess.Parameters.Add('-loglevel');
  FProcess.Parameters.Add('error');

  InputCount := 0;
  SysIdx := -1;
  MicIdx := -1;

  // System audio rides on a named pipe so stdin stays free for ffmpeg's
  // 'q' control character — that's how we shut it down cleanly.
  if Sys then
  begin
    if FLoop.IsFloat and (FLoop.BitsPerSample = 32) then SysFmt := 'f32le'
    else if FLoop.BitsPerSample = 16 then SysFmt := 's16le'
    else if FLoop.BitsPerSample = 32 then SysFmt := 's32le'
    else SysFmt := 'f32le';
    FProcess.Parameters.Add('-f');  FProcess.Parameters.Add(SysFmt);
    FProcess.Parameters.Add('-ar'); FProcess.Parameters.Add(IntToStr(FLoop.SampleRate));
    FProcess.Parameters.Add('-ac'); FProcess.Parameters.Add(IntToStr(FLoop.Channels));
    FProcess.Parameters.Add('-thread_queue_size'); FProcess.Parameters.Add('4096');
    // With raw PCM we know the format already — skip ffmpeg's probing
    // (which otherwise blocks input #2 until #1 has streamed enough).
    FProcess.Parameters.Add('-probesize');       FProcess.Parameters.Add('32');
    FProcess.Parameters.Add('-analyzeduration'); FProcess.Parameters.Add('0');
    FProcess.Parameters.Add('-i');  FProcess.Parameters.Add(FPipeName);
    SysIdx := InputCount;
    Inc(InputCount);
  end;
  if Mic then
  begin
    // Try WASAPI mic capture first — it initialises in ~50ms vs the
    // 500–1500ms that dshow takes (especially bluetooth). Falls back
    // to dshow if the device isn't found via the MMDevice enumerator.
    FMic := nil;
    if CreateMicPipe then
    begin
      TimePoint('mic pipe created');
      FMic := TWasapiLoopback.Create;
      FMic.OnData := nil;
      if not FMic.StartCapture(MicDevice) then
      begin
        AppendLog('WASAPI mic not available (' + FMic.StartError +
          '), falling back to dshow');
        FreeAndNil(FMic);
        CloseMicPipe;
      end
      else
        TimePoint('mic WASAPI capture started');
    end;
    if FMic <> nil then
    begin
      AppendLog(Format('WASAPI mic capture: %d Hz %d ch %d-bit float=%s',
        [FMic.SampleRate, FMic.Channels, FMic.BitsPerSample,
         BoolToStr(FMic.IsFloat, True)]));
      if FMic.IsFloat and (FMic.BitsPerSample = 32) then SysFmt := 'f32le'
      else if FMic.BitsPerSample = 16 then SysFmt := 's16le'
      else if FMic.BitsPerSample = 32 then SysFmt := 's32le'
      else SysFmt := 'f32le';
      FProcess.Parameters.Add('-f');  FProcess.Parameters.Add(SysFmt);
      FProcess.Parameters.Add('-ar'); FProcess.Parameters.Add(IntToStr(FMic.SampleRate));
      FProcess.Parameters.Add('-ac'); FProcess.Parameters.Add(IntToStr(FMic.Channels));
      FProcess.Parameters.Add('-thread_queue_size'); FProcess.Parameters.Add('4096');
      FProcess.Parameters.Add('-probesize');       FProcess.Parameters.Add('32');
      FProcess.Parameters.Add('-analyzeduration'); FProcess.Parameters.Add('0');
      FProcess.Parameters.Add('-i'); FProcess.Parameters.Add(FMicPipeName);
    end
    else
    begin
      FProcess.Parameters.Add('-f');         FProcess.Parameters.Add('dshow');
      FProcess.Parameters.Add('-rtbufsize'); FProcess.Parameters.Add('64M');
      FProcess.Parameters.Add('-thread_queue_size'); FProcess.Parameters.Add('4096');
      FProcess.Parameters.Add('-i');         FProcess.Parameters.Add('audio=' + ActualMic);
    end;
    MicIdx := InputCount;
    Inc(InputCount);
  end;

  // silenceremove keeps the output stream tight. Use peak detection on
  // the unprocessed signal (more forgiving for quiet voice than RMS),
  // a generous -50dB threshold, and reset PTS after the trim so the
  // mp3 muxer sees continuous timestamps.
  // Auto-calibrate threshold per mic. silenceremove with detection=rms
  // window=0.4 compares against a sliding RMS window — during speech
  // bursts that window is many dB above the static noise floor, so the
  // margin we add must scale with the mic's dynamic headroom.
  //   floor < -70 (very quiet, e.g. Logitech C270) → +30 dB
  //   -70..-45                                     → +15 dB
  //   -45..-30 (e.g. bluetooth HFP)                → +7  dB
  //   > -30                                        → +3  dB
  // FVadSensitivity (-10..+10 dB) is a user-tunable bias on top.
  // Default threshold. For sys-only-with-VAD we can be permissive —
  // WASAPI loopback produces pure zeros during silence, so quiet
  // musical passages need a lower threshold to survive (-32 dB cut
  // typical music dialogue/quiet sections).
  if Sys and not Mic then ThresholdDb := -55
  else                    ThresholdDb := -32;
  if AutoPauseOnSilence and Mic then
  begin
    if FCachedFloorDb > -300 then
    begin
      NoiseFloorDb := FCachedFloorDb;
      AppendLog(Format('Calibration: using cached floor %.1f dB', [NoiseFloorDb]));
    end
    else
    begin
      NoiseFloorDb := CalibrateMicNoiseFloorDb(ActualMic);
      TimePoint('mic calibration finished');
    end;
    FLastFloorDb := NoiseFloorDb;
    if NoiseFloorDb > -300 then
    begin
      if NoiseFloorDb < -70 then
        ThresholdDb := NoiseFloorDb + 30
      else if NoiseFloorDb < -45 then
        ThresholdDb := NoiseFloorDb + 15
      else if NoiseFloorDb < -30 then
        ThresholdDb := NoiseFloorDb + 7
      else
        ThresholdDb := NoiseFloorDb + 3;
      ThresholdDb := ThresholdDb + FVadSensitivity;
      if ThresholdDb < -75 then ThresholdDb := -75;
      if ThresholdDb > -35 then ThresholdDb := -35;
      AppendLog(Format('Calibration: floor %.1f dB +sens %d → threshold %.1f dB',
        [NoiseFloorDb, FVadSensitivity, ThresholdDb]));
    end
    else
      AppendLog('Calibration failed, using default threshold -32 dB');
  end;
  FVadThresholdDb := ThresholdDb;
  FCurrentRmsDb := -100;
  FVadSilent := True;  // assume silent until silencedetect tells us otherwise
  if AutoPauseOnSilence then
  begin
    // start_periods=1 trims leading silence; stop_periods=-1 cuts all
    // subsequent silences. Same threshold on both ends keeps resume
    // behaviour symmetric. asetpts renumbers so the mp3 muxer sees a
    // continuous timestamp series.
    SilenceChain := ',silenceremove=' +
      'start_periods=1:start_duration=0.05:start_threshold=' +
      StringReplace(FloatToStrF(ThresholdDb, ffFixed, 5, 1), ',', '.', []) + 'dB:' +
      'stop_periods=-1:stop_duration=0.7:stop_threshold=' +
      StringReplace(FloatToStrF(ThresholdDb, ffFixed, 5, 1), ',', '.', []) +
      'dB:detection=rms:window=0.4,asetpts=N/SR/TB';
  end
  else
    SilenceChain := '';

  // Build a complex filter graph that produces two labelled outputs:
  //   [mixclean] — post-mix, post-silenceremove (or just post-mix if
  //                VAD is off) — gets muxed to the mp3 file.
  //   [det]      — post-mix, fed through silencedetect → anullsink.
  //                Routed to a second null output so ffmpeg's per-
  //                output scheduler runs it at real time, independent
  //                of however the mp3 muxer paces itself during cuts.
  // The mp3 output cannot use -af on a complex-filtered stream, so
  // silenceremove has to live inside the filter graph.
  if (SysIdx >= 0) and (MicIdx >= 0) then
    GraphPre := Format(
      '[%d:a]anull[s];' +
      '[%d:a]aresample=async=1000:first_pts=0[m];' +
      '[s][m]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0',
      [SysIdx, MicIdx])
  else if SysIdx >= 0 then
    GraphPre := Format('[%d:a]anull', [SysIdx])
  else
    GraphPre := Format('[%d:a]aresample=async=1000:first_pts=0', [MicIdx]);

  // Record the full mix as-is during the session. When VAD is on,
  // silenceremove is applied later as a post-pass (TrimSilencePostPass)
  // — putting it into the live graph starves the mp3 muxer during
  // silence and stalls ffmpeg's filter scheduler.
  FProcess.Parameters.Add('-filter_complex');
  FProcess.Parameters.Add(GraphPre + '[mixclean]');
  FProcess.Parameters.Add('-map'); FProcess.Parameters.Add('[mixclean]');
  FProcess.Parameters.Add('-b:a');
  FProcess.Parameters.Add(IntToStr(Bitrate) + 'k');
  FProcess.Parameters.Add(FOutputFile);
  FNeedTrimPostPass := AutoPauseOnSilence;
  FTrimThresholdDb := ThresholdDb;

  FProcess.Options := [poUsePipes, poNoConsole];

  // Log the full cmdline for diagnostics.
  AppendLog('--- START rec out=' + FOutputFile +
            ' mic=' + BoolToStr(Mic, True) +
            ' sys=' + BoolToStr(Sys, True) +
            ' vad=' + BoolToStr(AutoPauseOnSilence, True) + ' ---');
  AppendLog('cmdline: ' + FProcess.Executable + ' ' + FProcess.Parameters.CommaText);

  try
    TimePoint('before ffmpeg Execute');
    FProcess.Execute;
    TimePoint('ffmpeg Execute returned');
    FStartTime := Now;
    FDrain := TStderrDrainThread.Create(Self);

    // If we have a named pipe waiting, accept ffmpeg's connection on
    // a background thread so we can time out instead of hanging.
    // Only after the pipe is connected do we route WASAPI samples
    // into it — see comment above the FLoop.Start call.
    if (FPipeHandle <> INVALID_HANDLE_VALUE) and Sys then
    begin
      AcceptLoopbackConnection;
      TimePoint('sys pipe accepted');
      if (FLoop <> nil) and (FPipeHandle <> INVALID_HANDLE_VALUE) then
      begin
        FLoop.ResetCadence;
        FLoop.OnData := @OnLoopData;
      end;
    end;
    if (FMicPipeHandle <> INVALID_HANDLE_VALUE) and (FMic <> nil) then
    begin
      AcceptMicConnection;
      TimePoint('mic pipe accepted');
      if (FMic <> nil) and (FMicPipeHandle <> INVALID_HANDLE_VALUE) then
        FMic.OnData := @OnMicData;
    end;
    TimePoint('Start done');

    Result := True;
  except
    on E: Exception do
    begin
      AppendLog('Start exception: ' + E.ClassName + ' ' + E.Message);
      FreeAndNil(FProcess);
      if FLoop <> nil then FreeAndNil(FLoop);
      if FMic <> nil then FreeAndNil(FMic);
      ClosePipe;
      CloseMicPipe;
      raise;
    end;
  end;
end;

procedure TAudioRecorder.AcceptLoopbackConnection;
var
  Connector: TPipeConnectThread;
  WaitedMs: Integer;
begin
  Connector := TPipeConnectThread.Create(FPipeHandle);
  try
    WaitedMs := 0;
    while WaitedMs < 3000 do
    begin
      if Connector.FConnected then Break;
      if Connector.Finished then Break;
      Sleep(20); Inc(WaitedMs, 20);
    end;
    if not Connector.FConnected then
    begin
      AppendLog('Pipe connect timeout — ffmpeg never opened ' + FPipeName);
      // Wake the connector by closing the pipe — its blocking call returns.
      ClosePipe;
      try Connector.WaitFor; except end;
    end
    else
      AppendLog('Pipe connected after ' + IntToStr(WaitedMs) + ' ms');
  finally
    Connector.Free;
  end;
end;

function TAudioRecorder.CreateMicPipe: Boolean;
const
  PIPE_ACCESS_OUTBOUND = $00000002;
  PIPE_TYPE_BYTE = 0;
  PIPE_WAIT = 0;
  PIPE_REJECT_REMOTE_CLIENTS = 8;
begin
  FMicPipeName := '\\.\pipe\timerecmic_' + IntToStr(GetCurrentProcessId) + '_' +
    IntToStr(GetTickCount64);
  FMicPipeHandle := CreateNamedPipeA(PAnsiChar(AnsiString(FMicPipeName)),
    PIPE_ACCESS_OUTBOUND,
    PIPE_TYPE_BYTE or PIPE_WAIT or PIPE_REJECT_REMOTE_CLIENTS,
    1, 2*1024*1024, 0, 0, nil);
  Result := FMicPipeHandle <> INVALID_HANDLE_VALUE;
end;

procedure TAudioRecorder.CloseMicPipe;
begin
  if FMicPipeHandle <> INVALID_HANDLE_VALUE then
  begin
    try FlushFileBuffers(FMicPipeHandle); except end;
    try CloseHandle(FMicPipeHandle); except end;
    FMicPipeHandle := INVALID_HANDLE_VALUE;
  end;
end;

procedure TAudioRecorder.AcceptMicConnection;
var
  Connector: TPipeConnectThread;
  Waited: Integer;
begin
  if FMicPipeHandle = INVALID_HANDLE_VALUE then Exit;
  Connector := TPipeConnectThread.Create(FMicPipeHandle);
  try
    Waited := 0;
    while Waited < 3000 do
    begin
      if Connector.FConnected then Break;
      if Connector.Finished then Break;
      Sleep(20); Inc(Waited, 20);
    end;
    if not Connector.FConnected then
    begin
      AppendLog('Mic pipe connect timeout');
      CloseMicPipe;
      try Connector.WaitFor; except end;
    end
    else
      AppendLog('Mic pipe connected after ' + IntToStr(Waited) + ' ms');
  finally
    Connector.Free;
  end;
end;

procedure TAudioRecorder.Stop;
const
  QSeq: array[0..1] of AnsiChar = ('q', #10);
var
  i: Integer;
begin
  AppendLog('--- STOP requested ---');
  if FLoop <> nil then
  begin
    try FLoop.Stop; except end;
    FreeAndNil(FLoop);
  end;
  if FMic <> nil then
  begin
    try FMic.Stop; except end;
    FreeAndNil(FMic);
  end;
  // Close the loopback / mic pipes so ffmpeg sees EOF on those inputs.
  FWriteLock.Enter;
  try
    ClosePipe;
    CloseMicPipe;
  finally
    FWriteLock.Leave;
  end;
  if FProcess = nil then Exit;
  try
    if FProcess.Running then
    begin
      // Send 'q' to ffmpeg's stdin for a clean shutdown — it flushes
      // muxer trailers and exits with code 0.
      try
        FProcess.Input.Write(QSeq[0], 2);
        FProcess.CloseInput;
      except end;
      // 3 sec graceful: bluetooth dshow and amix+silenceremove can
      // need that long to drain. Then force terminate.
      for i := 1 to 30 do
      begin
        if not FProcess.Running then Break;
        Sleep(100);
      end;
      if FProcess.Running then
      begin
        AppendLog('STOP: ffmpeg did not exit in 3s, terminating');
        try FProcess.Terminate(0); except end;
        for i := 1 to 10 do
        begin
          if not FProcess.Running then Break;
          Sleep(50);
        end;
      end;
    end;
  finally
    if FDrain <> nil then
    begin
      FDrain.Terminate;
      try FDrain.WaitFor; except end;
      FreeAndNil(FDrain);
    end;
    try FreeAndNil(FProcess); except FProcess := nil; end;
    AppendLog('--- STOP complete ---');
  end;
  // Now that the live recording is closed and the file is on disk,
  // run silenceremove as a post-pass if VAD was on.
  TrimSilencePostPass;
end;

function TAudioRecorder.IsRecording: Boolean;
begin
  Result := (FProcess <> nil) and FProcess.Running;
end;

function TAudioRecorder.CurrentFile: string;
begin
  Result := FOutputFile;
end;

function TAudioRecorder.ElapsedSec: Int64;
begin
  if IsRecording then
    Result := SecondsBetween(Now, FStartTime)
  else
    Result := 0;
end;

end.
