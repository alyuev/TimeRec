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
    FWriteLock: TCriticalSection;
    FPipeBroken: Boolean;
    FDrain: TStderrDrainThread;
    FLogPath: string;
    FPipeHandle: THandle;
    FPipeName: string;
  public
    FVadSensitivity: Integer;  // -10..+10 dB bias added to calibrated threshold
  private
    function FindFFmpeg: string;
    procedure OnLoopData(Data: Pointer; Bytes: Integer);
    procedure AppendLog(const S: string);
    function CreateLoopbackPipe: Boolean;
    procedure ClosePipe;
    procedure AcceptLoopbackConnection;
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
  N: LongInt;
  S: AnsiString;
begin
  while not Terminated do
  begin
    if (FOwner.FProcess = nil) or (not FOwner.FProcess.Running) then
    begin
      // Drain any remaining bytes after exit, then leave.
      if FOwner.FProcess <> nil then
        while FOwner.FProcess.Stderr.NumBytesAvailable > 0 do
        begin
          N := FOwner.FProcess.Stderr.Read(Buf, Min(SizeOf(Buf), FOwner.FProcess.Stderr.NumBytesAvailable));
          if N > 0 then
          begin
            SetLength(S, N); Move(Buf[0], S[1], N);
            FOwner.AppendLog('[ffmpeg] ' + S);
          end;
        end;
      Exit;
    end;
    if FOwner.FProcess.Stderr.NumBytesAvailable > 0 then
    begin
      N := FOwner.FProcess.Stderr.Read(Buf, Min(SizeOf(Buf), FOwner.FProcess.Stderr.NumBytesAvailable));
      if N > 0 then
      begin
        SetLength(S, N); Move(Buf[0], S[1], N);
        FOwner.AppendLog('[ffmpeg] ' + S);
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
  ActualMic, SysFmt, FilterExpr, SilenceChain: string;
  NoiseFloorDb, ThresholdDb: Double;
begin
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
  // know the device's native PCM format to declare to ffmpeg.
  if Sys then
  begin
    if not CreateLoopbackPipe then Exit;
    FLoop := TWasapiLoopback.Create;
    FLoop.OnData := @OnLoopData;
    if not FLoop.Start then
    begin
      FreeAndNil(FLoop);
      ClosePipe;
      Exit;
    end;
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
    FProcess.Parameters.Add('-i');  FProcess.Parameters.Add(FPipeName);
    SysIdx := InputCount;
    Inc(InputCount);
  end;
  if Mic then
  begin
    FProcess.Parameters.Add('-f');         FProcess.Parameters.Add('dshow');
    FProcess.Parameters.Add('-rtbufsize'); FProcess.Parameters.Add('64M');
    FProcess.Parameters.Add('-thread_queue_size'); FProcess.Parameters.Add('4096');
    FProcess.Parameters.Add('-i');         FProcess.Parameters.Add('audio=' + ActualMic);
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
  ThresholdDb := -32;
  if AutoPauseOnSilence and Mic then
  begin
    NoiseFloorDb := CalibrateMicNoiseFloorDb(ActualMic);
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
  if AutoPauseOnSilence then
  begin
    SilenceChain := ',silenceremove=' +
      'start_periods=0:' +
      'stop_periods=-1:stop_duration=0.7:stop_threshold=' +
      StringReplace(FloatToStrF(ThresholdDb, ffFixed, 5, 1), ',', '.', []) +
      'dB:detection=rms:window=0.4,asetpts=N/SR/TB';
  end
  else
    SilenceChain := '';

  if (SysIdx >= 0) and (MicIdx >= 0) then
  begin
    // sys passes through untouched. mic gets only mild aresample for
    // dshow clock drift. amix normalize=0 keeps original levels — sys
    // is mostly silence, so mic comes through cleanly. No agate (it
    // either killed quiet mics or chopped noisy ones); no post-mix
    // volume boost (that clipped). silenceremove uses RMS window
    // detection downstream for VAD on noisy mics.
    FilterExpr := Format(
      '[%d:a]anull[s];' +
      '[%d:a]aresample=async=1000:first_pts=0[m];' +
      '[s][m]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0',
      [SysIdx, MicIdx]) + SilenceChain;
    FProcess.Parameters.Add('-filter_complex');
    FProcess.Parameters.Add(FilterExpr);
  end
  else if AutoPauseOnSilence then
  begin
    // mic-only with VAD: just silenceremove.
    FProcess.Parameters.Add('-af');
    FProcess.Parameters.Add(Copy(SilenceChain, 2, MaxInt));
  end;

  FProcess.Parameters.Add('-b:a');
  FProcess.Parameters.Add(IntToStr(Bitrate) + 'k');
  FProcess.Parameters.Add(FOutputFile);

  FProcess.Options := [poUsePipes, poNoConsole];

  // Log the full cmdline for diagnostics.
  AppendLog('--- START rec out=' + FOutputFile +
            ' mic=' + BoolToStr(Mic, True) +
            ' sys=' + BoolToStr(Sys, True) +
            ' vad=' + BoolToStr(AutoPauseOnSilence, True) + ' ---');
  AppendLog('cmdline: ' + FProcess.Executable + ' ' + FProcess.Parameters.CommaText);

  try
    FProcess.Execute;
    FStartTime := Now;
    FDrain := TStderrDrainThread.Create(Self);

    // If we have a named pipe waiting, accept ffmpeg's connection on
    // a background thread so we can time out instead of hanging.
    if (FPipeHandle <> INVALID_HANDLE_VALUE) and Sys then
    begin
      AcceptLoopbackConnection;
    end;

    Result := True;
  except
    on E: Exception do
    begin
      AppendLog('Start exception: ' + E.ClassName + ' ' + E.Message);
      FreeAndNil(FProcess);
      if FLoop <> nil then FreeAndNil(FLoop);
      ClosePipe;
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
  // Close the loopback pipe so ffmpeg sees EOF on that input.
  FWriteLock.Enter;
  try
    ClosePipe;
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
