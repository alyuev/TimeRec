unit uwasapiloop;

// WASAPI loopback capture of the default render endpoint (system audio).
// Produces raw PCM in the device's native mix format and pushes it to a
// callback. No external installer required — works on Vista+.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Windows, ActiveX;

type
  TWasapiPcmCallback = procedure(Data: Pointer; Bytes: Integer) of object;

  TWasapiLoopback = class;

  TWasapiLoopThread = class(TThread)
  private
    FOwner: TWasapiLoopback;
    FStopEvent: THandle;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TWasapiLoopback);
    destructor Destroy; override;
    procedure SignalStop;
  end;

  TWasapiLoopback = class
  private
    FThread: TWasapiLoopThread;
    FOnData: TWasapiPcmCallback;
    FSampleRate: Integer;
    FChannels: Integer;
    FBitsPerSample: Integer;
    FIsFloat: Boolean;
    FFormatReady: THandle;
    FStartError: string;
  public
    constructor Create;
    destructor Destroy; override;
    function Start: Boolean;
    procedure Stop;
    function Running: Boolean;
    property OnData: TWasapiPcmCallback read FOnData write FOnData;
    property SampleRate: Integer read FSampleRate;
    property Channels: Integer read FChannels;
    property BitsPerSample: Integer read FBitsPerSample;
    property IsFloat: Boolean read FIsFloat;
    property StartError: string read FStartError;
  end;

implementation

const
  CLSCTX_ALL = $17;
  COINIT_MULTITHREADED = $0;

  CLSID_MMDeviceEnumerator: TGUID = '{BCDE0395-E52F-467C-8E3D-C4579291692E}';
  IID_IMMDeviceEnumerator: TGUID = '{A95664D2-9614-4F35-A746-DE8DB63617E6}';
  IID_IAudioClient:        TGUID = '{1CB9AD4C-DBFA-4c32-B178-C2F568A703B2}';
  IID_IAudioCaptureClient: TGUID = '{C8ADBD64-E71E-48a0-A4DE-185C395CD317}';

  eRender   = 0;
  eConsole  = 0;

  AUDCLNT_SHAREMODE_SHARED      = 0;
  AUDCLNT_STREAMFLAGS_LOOPBACK  = $00020000;
  AUDCLNT_STREAMFLAGS_EVENTCALLBACK = $00040000;
  AUDCLNT_BUFFERFLAGS_SILENT    = 2;

  WAVE_FORMAT_PCM        = 1;
  WAVE_FORMAT_IEEE_FLOAT = 3;
  WAVE_FORMAT_EXTENSIBLE = $FFFE;

  KSDATAFORMAT_SUBTYPE_PCM:        TGUID = '{00000001-0000-0010-8000-00aa00389b71}';
  KSDATAFORMAT_SUBTYPE_IEEE_FLOAT: TGUID = '{00000003-0000-0010-8000-00aa00389b71}';

type
  REFERENCE_TIME = Int64;

  PWAVEFORMATEX = ^TWAVEFORMATEX;
  TWAVEFORMATEX = packed record
    wFormatTag: Word;
    nChannels: Word;
    nSamplesPerSec: DWORD;
    nAvgBytesPerSec: DWORD;
    nBlockAlign: Word;
    wBitsPerSample: Word;
    cbSize: Word;
  end;

  PWAVEFORMATEXTENSIBLE = ^TWAVEFORMATEXTENSIBLE;
  TWAVEFORMATEXTENSIBLE = packed record
    Format: TWAVEFORMATEX;
    wValidBitsPerSample: Word;
    dwChannelMask: DWORD;
    SubFormat: TGUID;
  end;

  IMMDevice = interface(IUnknown)
    ['{D666063F-1587-4E43-81F1-B948E807363F}']
    function Activate(const iid: TGUID; dwClsCtx: DWORD;
      pActivationParams: Pointer; out ppInterface): HRESULT; stdcall;
    function OpenPropertyStore(stgmAccess: DWORD; out ppProperties): HRESULT; stdcall;
    function GetId(out ppstrId: PWideChar): HRESULT; stdcall;
    function GetState(out pdwState: DWORD): HRESULT; stdcall;
  end;

  IMMDeviceCollection = interface(IUnknown)
    ['{0BD7A1BE-7A1A-44DB-8397-CC5392387B5E}']
    function GetCount(out pcDevices: UINT): HRESULT; stdcall;
    function Item(nDevice: UINT; out ppDevice: IMMDevice): HRESULT; stdcall;
  end;

  IMMNotificationClient = interface(IUnknown)
    ['{7991EEC9-7E89-4D85-8390-6C703CEC60C0}']
  end;

  IMMDeviceEnumerator = interface(IUnknown)
    ['{A95664D2-9614-4F35-A746-DE8DB63617E6}']
    function EnumAudioEndpoints(dataFlow: DWORD; dwStateMask: DWORD;
      out ppDevices: IMMDeviceCollection): HRESULT; stdcall;
    function GetDefaultAudioEndpoint(dataFlow: DWORD; role: DWORD;
      out ppEndpoint: IMMDevice): HRESULT; stdcall;
    function GetDevice(pwstrId: PWideChar; out ppDevice: IMMDevice): HRESULT; stdcall;
    function RegisterEndpointNotificationCallback(pClient: IMMNotificationClient): HRESULT; stdcall;
    function UnregisterEndpointNotificationCallback(pClient: IMMNotificationClient): HRESULT; stdcall;
  end;

  IAudioCaptureClient = interface(IUnknown)
    ['{C8ADBD64-E71E-48a0-A4DE-185C395CD317}']
    function GetBuffer(out ppData: PByte; out pNumFramesToRead: UINT;
      out pdwFlags: DWORD; pu64DevicePosition: PUInt64;
      pu64QPCPosition: PUInt64): HRESULT; stdcall;
    function ReleaseBuffer(NumFramesRead: UINT): HRESULT; stdcall;
    function GetNextPacketSize(out pNumFramesInNextPacket: UINT): HRESULT; stdcall;
  end;

  IAudioClient = interface(IUnknown)
    ['{1CB9AD4C-DBFA-4c32-B178-C2F568A703B2}']
    function Initialize_(ShareMode: DWORD; StreamFlags: DWORD;
      hnsBufferDuration: REFERENCE_TIME; hnsPeriodicity: REFERENCE_TIME;
      pFormat: PWAVEFORMATEX; AudioSessionGuid: PGUID): HRESULT; stdcall;
    function GetBufferSize(out pNumBufferFrames: UINT): HRESULT; stdcall;
    function GetStreamLatency(out phnsLatency: REFERENCE_TIME): HRESULT; stdcall;
    function GetCurrentPadding(out pNumPaddingFrames: UINT): HRESULT; stdcall;
    function IsFormatSupported(ShareMode: DWORD; pFormat: PWAVEFORMATEX;
      ppClosestMatch: PPointer): HRESULT; stdcall;
    function GetMixFormat(out ppDeviceFormat: PWAVEFORMATEX): HRESULT; stdcall;
    function GetDevicePeriod(phnsDefaultDevicePeriod: PInt64;
      phnsMinimumDevicePeriod: PInt64): HRESULT; stdcall;
    function Start_: HRESULT; stdcall;
    function Stop_: HRESULT; stdcall;
    function Reset_: HRESULT; stdcall;
    function SetEventHandle(eventHandle: THandle): HRESULT; stdcall;
    function GetService(const riid: TGUID; out ppv): HRESULT; stdcall;
  end;

function CoTaskMemFree(p: Pointer): HRESULT; stdcall; external 'ole32.dll';

constructor TWasapiLoopback.Create;
begin
  inherited;
  FFormatReady := CreateEvent(nil, True, False, nil);
end;

destructor TWasapiLoopback.Destroy;
begin
  Stop;
  if FFormatReady <> 0 then CloseHandle(FFormatReady);
  inherited;
end;

function TWasapiLoopback.Start: Boolean;
begin
  Result := False;
  if FThread <> nil then Exit;
  FStartError := '';
  ResetEvent(FFormatReady);
  FThread := TWasapiLoopThread.Create(Self);
  // Wait briefly for the thread to either succeed initialising and
  // signal FFormatReady, or to die early with an error.
  if WaitForSingleObject(FFormatReady, 2000) <> WAIT_OBJECT_0 then
  begin
    // Treat as failure.
    Stop;
    Exit;
  end;
  if FStartError <> '' then
  begin
    Stop;
    Exit;
  end;
  Result := True;
end;

procedure TWasapiLoopback.Stop;
begin
  if FThread = nil then Exit;
  FThread.SignalStop;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

function TWasapiLoopback.Running: Boolean;
begin
  Result := (FThread <> nil) and (not FThread.Finished);
end;

{ TWasapiLoopThread }

constructor TWasapiLoopThread.Create(AOwner: TWasapiLoopback);
begin
  FOwner := AOwner;
  FStopEvent := CreateEvent(nil, True, False, nil);
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TWasapiLoopThread.Destroy;
begin
  if FStopEvent <> 0 then CloseHandle(FStopEvent);
  inherited;
end;

procedure TWasapiLoopThread.SignalStop;
begin
  if FStopEvent <> 0 then SetEvent(FStopEvent);
end;

function CoInitializeEx(p: Pointer; coInit: DWORD): HRESULT; stdcall;
  external 'ole32.dll' name 'CoInitializeEx';

procedure TWasapiLoopThread.Execute;
var
  hr: HRESULT;
  Enum: IMMDeviceEnumerator;
  Dev: IMMDevice;
  Client: IAudioClient;
  Capture: IAudioCaptureClient;
  Fmt: PWAVEFORMATEX;
  Ext: PWAVEFORMATEXTENSIBLE;
  BufFrames: UINT;
  Data: PByte;
  Frames: UINT;
  Flags: DWORD;
  PacketLen: UINT;
  BytesPerFrame: Integer;
  Silence: array of Byte;
  ComInited: Boolean;
begin
  ComInited := False;
  Fmt := nil;
  try
    hr := CoInitializeEx(nil, COINIT_MULTITHREADED);
    if (hr = S_OK) or (hr = S_FALSE) then ComInited := True;

    hr := CoCreateInstance(CLSID_MMDeviceEnumerator, nil, CLSCTX_ALL,
      IID_IMMDeviceEnumerator, Enum);
    if Failed(hr) then begin FOwner.FStartError := 'CoCreateInstance failed'; SetEvent(FOwner.FFormatReady); Exit; end;

    hr := Enum.GetDefaultAudioEndpoint(eRender, eConsole, Dev);
    if Failed(hr) then begin FOwner.FStartError := 'No default render endpoint'; SetEvent(FOwner.FFormatReady); Exit; end;

    hr := Dev.Activate(IID_IAudioClient, CLSCTX_ALL, nil, Client);
    if Failed(hr) then begin FOwner.FStartError := 'Activate IAudioClient failed'; SetEvent(FOwner.FFormatReady); Exit; end;

    hr := Client.GetMixFormat(Fmt);
    if Failed(hr) or (Fmt = nil) then begin FOwner.FStartError := 'GetMixFormat failed'; SetEvent(FOwner.FFormatReady); Exit; end;

    FOwner.FSampleRate := Fmt^.nSamplesPerSec;
    FOwner.FChannels := Fmt^.nChannels;
    FOwner.FBitsPerSample := Fmt^.wBitsPerSample;
    BytesPerFrame := Fmt^.nBlockAlign;
    if Fmt^.wFormatTag = WAVE_FORMAT_IEEE_FLOAT then
      FOwner.FIsFloat := True
    else if Fmt^.wFormatTag = WAVE_FORMAT_EXTENSIBLE then
    begin
      Ext := PWAVEFORMATEXTENSIBLE(Fmt);
      FOwner.FIsFloat := IsEqualGUID(Ext^.SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
    end
    else
      FOwner.FIsFloat := False;

    // 200ms internal buffer; loopback uses shared mode.
    hr := Client.Initialize_(AUDCLNT_SHAREMODE_SHARED,
      AUDCLNT_STREAMFLAGS_LOOPBACK, 2000000, 0, Fmt, nil);
    if Failed(hr) then begin FOwner.FStartError := 'IAudioClient.Initialize failed'; SetEvent(FOwner.FFormatReady); Exit; end;

    hr := Client.GetBufferSize(BufFrames);
    if Failed(hr) then begin FOwner.FStartError := 'GetBufferSize failed'; SetEvent(FOwner.FFormatReady); Exit; end;

    hr := Client.GetService(IID_IAudioCaptureClient, Capture);
    if Failed(hr) then begin FOwner.FStartError := 'GetService capture failed'; SetEvent(FOwner.FFormatReady); Exit; end;

    hr := Client.Start_;
    if Failed(hr) then begin FOwner.FStartError := 'IAudioClient.Start failed'; SetEvent(FOwner.FFormatReady); Exit; end;

    // Format & success — signal owner.
    SetEvent(FOwner.FFormatReady);

    while not Terminated do
    begin
      if WaitForSingleObject(FStopEvent, 10) = WAIT_OBJECT_0 then Break;

      while True do
      begin
        hr := Capture.GetNextPacketSize(PacketLen);
        if Failed(hr) or (PacketLen = 0) then Break;

        hr := Capture.GetBuffer(Data, Frames, Flags, nil, nil);
        if Failed(hr) then Break;

        if (Flags and AUDCLNT_BUFFERFLAGS_SILENT) <> 0 then
        begin
          // Emit silence of equivalent size so the downstream encoder
          // gets a continuous stream and timing stays in sync.
          if Length(Silence) < Integer(Frames) * BytesPerFrame then
            SetLength(Silence, Integer(Frames) * BytesPerFrame);
          FillChar(Silence[0], Integer(Frames) * BytesPerFrame, 0);
          if Assigned(FOwner.FOnData) then
            FOwner.FOnData(@Silence[0], Integer(Frames) * BytesPerFrame);
        end
        else if Assigned(FOwner.FOnData) then
          FOwner.FOnData(Data, Integer(Frames) * BytesPerFrame);

        Capture.ReleaseBuffer(Frames);
      end;
    end;

    Client.Stop_;
  finally
    if Fmt <> nil then CoTaskMemFree(Fmt);
    Capture := nil;
    Client := nil;
    Dev := nil;
    Enum := nil;
    if ComInited then CoUninitialize;
  end;
end;

end.
