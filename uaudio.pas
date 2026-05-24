unit uaudio;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process, syncobjs, uwasapiloop;

function Min(A, B: LongInt): LongInt; inline;

type
  TAudioQuality = (aqLow, aqMid, aqHigh);

  TAudioRecorder = class
  private
    FProcess: TProcess;
    FOutputFile: string;
    FStartTime: TDateTime;
    FAppDir: string;
    FLoop: TWasapiLoopback;
    FWriteLock: TCriticalSection;
    FPipeBroken: Boolean;
    function FindFFmpeg: string;
    procedure OnLoopData(Data: Pointer; Bytes: Integer);
  public
    constructor Create(const AAppDir: string);
    destructor Destroy; override;
    function Start(const OutFile: string; Mic, Sys: Boolean;
      Quality: TAudioQuality; const MicDevice: string): Boolean;
    procedure Stop;
    function IsRecording: Boolean;
    function CurrentFile: string;
    function ElapsedSec: Int64;
    function FFmpegAvailable: Boolean;
    function DetectFirstMic: string;
    procedure ListMics(AOut: TStrings);
  end;

const
  QualityBitrate: array[TAudioQuality] of Integer = (64, 128, 256);

implementation

uses
  DateUtils;

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
end;

destructor TAudioRecorder.Destroy;
begin
  if IsRecording then Stop;
  FWriteLock.Free;
  inherited;
end;

procedure TAudioRecorder.OnLoopData(Data: Pointer; Bytes: Integer);
begin
  if FPipeBroken or (FProcess = nil) or (Data = nil) or (Bytes <= 0) then Exit;
  FWriteLock.Enter;
  try
    if FProcess = nil then Exit;
    try
      FProcess.Input.Write(Data^, Bytes);
    except
      FPipeBroken := True;
    end;
  finally
    FWriteLock.Leave;
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
  Quality: TAudioQuality; const MicDevice: string): Boolean;
var
  Bitrate, InputCount, SysIdx, MicIdx: Integer;
  ActualMic, SysFmt: string;
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
    FLoop := TWasapiLoopback.Create;
    FLoop.OnData := @OnLoopData;
    if not FLoop.Start then
    begin
      FreeAndNil(FLoop);
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

  // Input 0 must be the pipe-fed one when present — ffmpeg reads
  // stdin as pipe:0.
  if Sys then
  begin
    if FLoop.IsFloat and (FLoop.BitsPerSample = 32) then SysFmt := 'f32le'
    else if FLoop.BitsPerSample = 16 then SysFmt := 's16le'
    else if FLoop.BitsPerSample = 32 then SysFmt := 's32le'
    else SysFmt := 'f32le';
    FProcess.Parameters.Add('-f');  FProcess.Parameters.Add(SysFmt);
    FProcess.Parameters.Add('-ar'); FProcess.Parameters.Add(IntToStr(FLoop.SampleRate));
    FProcess.Parameters.Add('-ac'); FProcess.Parameters.Add(IntToStr(FLoop.Channels));
    FProcess.Parameters.Add('-i');  FProcess.Parameters.Add('pipe:0');
    SysIdx := InputCount;
    Inc(InputCount);
  end;
  if Mic then
  begin
    FProcess.Parameters.Add('-f'); FProcess.Parameters.Add('dshow');
    FProcess.Parameters.Add('-i'); FProcess.Parameters.Add('audio=' + ActualMic);
    MicIdx := InputCount;
    Inc(InputCount);
  end;

  if (SysIdx >= 0) and (MicIdx >= 0) then
  begin
    FProcess.Parameters.Add('-filter_complex');
    FProcess.Parameters.Add(Format(
      '[%d:a]aresample=async=1:first_pts=0[s];' +
      '[%d:a]aresample=async=1:first_pts=0[m];' +
      '[s][m]amix=inputs=2:duration=shortest:dropout_transition=0,' +
      'volume=2', [SysIdx, MicIdx]));
  end;

  FProcess.Parameters.Add('-b:a');
  FProcess.Parameters.Add(IntToStr(Bitrate) + 'k');
  FProcess.Parameters.Add(FOutputFile);

  FProcess.Options := [poUsePipes, poNoConsole];
  try
    FProcess.Execute;
    FStartTime := Now;
    Result := True;
  except
    on E: Exception do
    begin
      FreeAndNil(FProcess);
      if FLoop <> nil then FreeAndNil(FLoop);
      raise;
    end;
  end;
end;

procedure TAudioRecorder.Stop;
const
  QSeq: array[0..1] of AnsiChar = ('q', #10);
var
  i: Integer;
  HadLoop: Boolean;
begin
  HadLoop := FLoop <> nil;
  // Stop the WASAPI loopback first so no more writes hit the pipe.
  if FLoop <> nil then
  begin
    try FLoop.Stop; except end;
    FreeAndNil(FLoop);
  end;
  if FProcess = nil then Exit;
  try
    if FProcess.Running then
    begin
      FWriteLock.Enter;
      try
        if HadLoop then
          // Pipe-fed input: closing stdin signals EOF and the amix
          // shortest-duration rule unwinds the graph cleanly.
          try FProcess.CloseInput; except end
        else
          // dshow-only inputs: send the ffmpeg 'q' keystroke on stdin
          // for a graceful flush, then close.
          try
            FProcess.Input.Write(QSeq[0], 2);
            FProcess.CloseInput;
          except end;
      finally
        FWriteLock.Leave;
      end;
      for i := 1 to 50 do
      begin
        if not FProcess.Running then Break;
        Sleep(100);
      end;
      if FProcess.Running then
        try FProcess.Terminate(0); except end;
    end;
  finally
    try FreeAndNil(FProcess); except FProcess := nil; end;
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
