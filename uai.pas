unit uai;

// AI transcription client. Talks to any OpenAI-compatible endpoint via
// WinHTTP — no OpenSSL DLLs needed, HTTPS via Schannel. Supports local
// servers (LM Studio, Lemonade) and OpenAI cloud. Ollama is NOT
// compatible (no Whisper serving).

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Windows;

type
  TAISettings = record
    Endpoint: string;   // e.g. http://localhost:1234/v1
    ApiKey: string;     // optional for local servers
    Model: string;      // e.g. whisper-1, faster-whisper-large-v3
    Language: string;   // '' = auto, 'ru', 'en', ...
    Enabled: Boolean;
  end;

  TTranscribeResult = record
    Ok: Boolean;
    Text: string;       // transcribed text on success
    ErrorMsg: string;   // human-readable error on failure
    HttpStatus: Integer;
  end;

  TTranscribeThread = class;
  TTranscribeCallback = procedure(Result: TTranscribeResult) of object;

  TTranscribeThread = class(TThread)
  private
    FSettings: TAISettings;
    FAudioPath: string;
    FResult: TTranscribeResult;
    FCallback: TTranscribeCallback;
    procedure DoCallback;
  protected
    procedure Execute; override;
  public
    constructor Create(const ASettings: TAISettings;
      const AAudioPath: string; ACallback: TTranscribeCallback);
  end;

// One-shot synchronous helpers (used by Settings dialog "Test" button
// and worker thread).
function HttpGetJson(const Url, ApiKey: string;
  out Response: string; out Status: Integer): Boolean;
function HttpPostMultipart(const Url, ApiKey, FilePath, FileFieldName,
  FileMime: string; ExtraFields: TStrings;
  out Response: string; out Status: Integer): Boolean;
function TranscribeFileSync(const Settings: TAISettings;
  const AudioPath: string): TTranscribeResult;
function ExtractTextFromJson(const Json: string): string;
function TranscriptPath(const AudioPath: string): string;

implementation

uses
  fpjson, jsonparser;

// ---- WinHTTP bindings ----------------------------------------------------
const
  WinHttpDll = 'winhttp.dll';
  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0;
  WINHTTP_FLAG_SECURE = $00800000;
  WINHTTP_QUERY_STATUS_CODE = 19;
  WINHTTP_QUERY_FLAG_NUMBER = $20000000;
  INTERNET_DEFAULT_HTTP_PORT  = 80;
  INTERNET_DEFAULT_HTTPS_PORT = 443;
  WINHTTP_NO_REFERER: PWideChar = nil;
  WINHTTP_DEFAULT_ACCEPT_TYPES: Pointer = nil;
  WINHTTP_NO_ADDITIONAL_HEADERS: PWideChar = nil;
  WINHTTP_NO_REQUEST_DATA: Pointer = nil;
  WINHTTP_HEADER_NAME_BY_INDEX: PWideChar = nil;

function WinHttpOpen(pszAgent: PWideChar; dwAccessType: DWORD;
  pszProxy, pszProxyBypass: PWideChar; dwFlags: DWORD): THandle; stdcall;
  external WinHttpDll;
function WinHttpConnect(hSession: THandle; pszServerName: PWideChar;
  nServerPort: Word; dwReserved: DWORD): THandle; stdcall; external WinHttpDll;
function WinHttpOpenRequest(hConnect: THandle; pwszVerb, pwszObjectName,
  pwszVersion, pwszReferrer: PWideChar; ppwszAcceptTypes: Pointer;
  dwFlags: DWORD): THandle; stdcall; external WinHttpDll;
function WinHttpSendRequest(hRequest: THandle; lpszHeaders: PWideChar;
  dwHeadersLength: DWORD; lpOptional: Pointer; dwOptionalLength,
  dwTotalLength, dwContext: DWORD_PTR): BOOL; stdcall; external WinHttpDll;
function WinHttpAddRequestHeaders(hRequest: THandle; pwszHeaders: PWideChar;
  dwHeadersLength, dwModifiers: DWORD): BOOL; stdcall; external WinHttpDll;
function WinHttpWriteData(hRequest: THandle; lpBuffer: Pointer;
  dwNumberOfBytesToWrite: DWORD; var lpdwNumberOfBytesWritten: DWORD): BOOL;
  stdcall; external WinHttpDll;
function WinHttpReceiveResponse(hRequest: THandle; lpReserved: Pointer): BOOL;
  stdcall; external WinHttpDll;
function WinHttpQueryHeaders(hRequest: THandle; dwInfoLevel: DWORD;
  pwszName: PWideChar; lpBuffer: Pointer; var lpdwBufferLength: DWORD;
  var lpdwIndex: DWORD): BOOL; stdcall; external WinHttpDll;
function WinHttpReadData(hRequest: THandle; lpBuffer: Pointer;
  dwNumberOfBytesToRead: DWORD; var lpdwNumberOfBytesRead: DWORD): BOOL;
  stdcall; external WinHttpDll;
function WinHttpCloseHandle(hInternet: THandle): BOOL; stdcall;
  external WinHttpDll;
function WinHttpQueryDataAvailable(hRequest: THandle;
  var lpdwNumberOfBytesAvailable: DWORD): BOOL; stdcall; external WinHttpDll;

// ---- URL parsing ---------------------------------------------------------

procedure SplitUrl(const Url: string; out Secure: Boolean;
  out Host: string; out Port: Word; out Path: string);
var
  Rest: string;
  i: Integer;
begin
  Secure := False;
  Host := '';
  Path := '/';
  Port := INTERNET_DEFAULT_HTTP_PORT;
  if Pos('https://', LowerCase(Url)) = 1 then
  begin
    Secure := True;
    Port := INTERNET_DEFAULT_HTTPS_PORT;
    Rest := Copy(Url, 9, MaxInt);
  end
  else if Pos('http://', LowerCase(Url)) = 1 then
    Rest := Copy(Url, 8, MaxInt)
  else
    Rest := Url;
  i := Pos('/', Rest);
  if i > 0 then
  begin
    Host := Copy(Rest, 1, i - 1);
    Path := Copy(Rest, i, MaxInt);
  end
  else
    Host := Rest;
  i := Pos(':', Host);
  if i > 0 then
  begin
    Port := StrToIntDef(Copy(Host, i + 1, MaxInt), Port);
    Host := Copy(Host, 1, i - 1);
  end;
end;

// ---- Core request --------------------------------------------------------

function DoRequest(const Method, Url, ApiKey, ExtraHeaders: string;
  Body: Pointer; BodyLen: DWORD;
  out Response: string; out Status: Integer): Boolean;
var
  Secure: Boolean;
  Host, Path: string;
  Port: Word;
  Session, Connect, Request: THandle;
  Flags, BytesWritten, BytesRead, Avail, BufLen, Idx: DWORD;
  Buf: array[0..8191] of Byte;
  WAgent, WMethod, WHost, WPath, WHeaders: UnicodeString;
  AllHeaders: string;
begin
  Result := False;
  Response := '';
  Status := 0;

  SplitUrl(Url, Secure, Host, Port, Path);
  if Host = '' then begin Response := 'empty host'; Exit; end;

  WAgent := 'TimeRec/5.0';
  Session := WinHttpOpen(PWideChar(WAgent), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
    nil, nil, 0);
  if Session = 0 then begin Response := 'WinHttpOpen failed'; Exit; end;
  try
    WHost := UnicodeString(Host);
    Connect := WinHttpConnect(Session, PWideChar(WHost), Port, 0);
    if Connect = 0 then begin Response := 'WinHttpConnect failed'; Exit; end;
    try
      WMethod := UnicodeString(Method);
      WPath := UnicodeString(Path);
      Flags := 0;
      if Secure then Flags := WINHTTP_FLAG_SECURE;
      Request := WinHttpOpenRequest(Connect, PWideChar(WMethod),
        PWideChar(WPath), nil, nil, nil, Flags);
      if Request = 0 then begin Response := 'WinHttpOpenRequest failed'; Exit; end;
      try
        AllHeaders := ExtraHeaders;
        if ApiKey <> '' then
          AllHeaders := AllHeaders + 'Authorization: Bearer ' + ApiKey + #13#10;
        if AllHeaders <> '' then
        begin
          WHeaders := UnicodeString(AllHeaders);
          WinHttpAddRequestHeaders(Request, PWideChar(WHeaders),
            Length(WHeaders), $A0000000);  // ADD | REPLACE
        end;
        if not WinHttpSendRequest(Request, nil, 0, nil, 0, BodyLen, 0) then
        begin
          Response := 'WinHttpSendRequest failed: ' + IntToStr(GetLastError);
          Exit;
        end;
        if (Body <> nil) and (BodyLen > 0) then
        begin
          if not WinHttpWriteData(Request, Body, BodyLen, BytesWritten) then
          begin
            Response := 'WinHttpWriteData failed: ' + IntToStr(GetLastError);
            Exit;
          end;
        end;
        if not WinHttpReceiveResponse(Request, nil) then
        begin
          Response := 'WinHttpReceiveResponse failed: ' + IntToStr(GetLastError);
          Exit;
        end;
        // Query status
        BufLen := SizeOf(DWORD);
        Idx := 0;
        WinHttpQueryHeaders(Request,
          WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
          nil, @Status, BufLen, Idx);
        // Read body
        repeat
          Avail := 0;
          if not WinHttpQueryDataAvailable(Request, Avail) then Break;
          if Avail = 0 then Break;
          if Avail > SizeOf(Buf) then Avail := SizeOf(Buf);
          if not WinHttpReadData(Request, @Buf[0], Avail, BytesRead) then Break;
          if BytesRead = 0 then Break;
          SetLength(Response, Length(Response) + Integer(BytesRead));
          Move(Buf[0], Response[Length(Response) - Integer(BytesRead) + 1], BytesRead);
        until False;
        Result := (Status >= 200) and (Status < 300);
      finally
        WinHttpCloseHandle(Request);
      end;
    finally
      WinHttpCloseHandle(Connect);
    end;
  finally
    WinHttpCloseHandle(Session);
  end;
end;

function HttpGetJson(const Url, ApiKey: string;
  out Response: string; out Status: Integer): Boolean;
begin
  Result := DoRequest('GET', Url, ApiKey, 'Accept: application/json'#13#10,
    nil, 0, Response, Status);
end;

// ---- Multipart builder ---------------------------------------------------

function ReadFileBytes(const Path: string; out Data: TBytes): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  if not FileExists(Path) then Exit;
  FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Data, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Data[0], FS.Size);
    Result := True;
  finally
    FS.Free;
  end;
end;

procedure AppendBytes(var Buf: TBytes; const S: AnsiString);
var L: Integer;
begin
  L := Length(Buf);
  SetLength(Buf, L + Length(S));
  if Length(S) > 0 then Move(S[1], Buf[L], Length(S));
end;

procedure AppendRawBytes(var Buf: TBytes; const Src: TBytes);
var L: Integer;
begin
  L := Length(Buf);
  SetLength(Buf, L + Length(Src));
  if Length(Src) > 0 then Move(Src[0], Buf[L], Length(Src));
end;

function HttpPostMultipart(const Url, ApiKey, FilePath, FileFieldName,
  FileMime: string; ExtraFields: TStrings;
  out Response: string; out Status: Integer): Boolean;
var
  Boundary, Headers, FName: string;
  i: Integer;
  Body, FileData: TBytes;
begin
  Result := False;
  Status := 0;
  Response := '';
  if not ReadFileBytes(FilePath, FileData) then
  begin
    Response := 'file not found: ' + FilePath;
    Exit;
  end;
  Boundary := '----TimeRecBoundary' + FormatDateTime('yyyymmddhhnnsszzz', Now);
  FName := ExtractFileName(FilePath);

  SetLength(Body, 0);
  if ExtraFields <> nil then
    for i := 0 to ExtraFields.Count - 1 do
    begin
      AppendBytes(Body, '--' + Boundary + #13#10);
      AppendBytes(Body, 'Content-Disposition: form-data; name="' +
        ExtraFields.Names[i] + '"' + #13#10#13#10);
      AppendBytes(Body, AnsiString(UTF8Encode(ExtraFields.ValueFromIndex[i]))
        + #13#10);
    end;
  AppendBytes(Body, '--' + Boundary + #13#10);
  AppendBytes(Body, 'Content-Disposition: form-data; name="' + FileFieldName +
    '"; filename="' + FName + '"' + #13#10);
  AppendBytes(Body, 'Content-Type: ' + FileMime + #13#10#13#10);
  AppendRawBytes(Body, FileData);
  AppendBytes(Body, #13#10'--' + Boundary + '--'#13#10);

  Headers := 'Content-Type: multipart/form-data; boundary=' + Boundary + #13#10;
  if Length(Body) > 0 then
    Result := DoRequest('POST', Url, ApiKey, Headers,
      @Body[0], Length(Body), Response, Status)
  else
    Result := DoRequest('POST', Url, ApiKey, Headers,
      nil, 0, Response, Status);
end;

// ---- JSON helpers --------------------------------------------------------

function ExtractTextFromJson(const Json: string): string;
var
  J, V: TJSONData;
begin
  Result := '';
  try
    J := GetJSON(Json);
    try
      if J is TJSONObject then
      begin
        V := TJSONObject(J).Find('text');
        if (V <> nil) and (V.JSONType = jtString) then
          Result := V.AsString;
      end;
    finally
      J.Free;
    end;
  except
    // Not JSON or no text field — return empty
  end;
end;

// ---- High-level transcribe ----------------------------------------------

function TranscriptPath(const AudioPath: string): string;
begin
  Result := ChangeFileExt(AudioPath, '.txt');
end;

function TranscribeFileSync(const Settings: TAISettings;
  const AudioPath: string): TTranscribeResult;
var
  Url, Resp: string;
  Status: Integer;
  Ok: Boolean;
  Fields: TStringList;
begin
  Result.Ok := False;
  Result.Text := '';
  Result.ErrorMsg := '';
  Result.HttpStatus := 0;
  if (Settings.Endpoint = '') or (Settings.Model = '') then
  begin
    Result.ErrorMsg := 'Подключение к ИИ не настроено';
    Exit;
  end;
  if not FileExists(AudioPath) then
  begin
    Result.ErrorMsg := 'Файл не найден: ' + AudioPath;
    Exit;
  end;
  Url := Settings.Endpoint;
  if Url[Length(Url)] = '/' then SetLength(Url, Length(Url) - 1);
  Url := Url + '/audio/transcriptions';

  Fields := TStringList.Create;
  try
    Fields.Add('model=' + Settings.Model);
    if Settings.Language <> '' then
      Fields.Add('language=' + Settings.Language);
    Ok := HttpPostMultipart(Url, Settings.ApiKey, AudioPath, 'file',
      'audio/mpeg', Fields, Resp, Status);
  finally
    Fields.Free;
  end;
  Result.HttpStatus := Status;
  if not Ok then
  begin
    if Resp = '' then Resp := 'HTTP ' + IntToStr(Status);
    Result.ErrorMsg := 'Запрос не выполнен: ' + Copy(Resp, 1, 500);
    Exit;
  end;
  Result.Text := ExtractTextFromJson(Resp);
  if Result.Text = '' then
  begin
    Result.ErrorMsg := 'В ответе нет поля «text». Ответ сервера: ' +
      Copy(Resp, 1, 500);
    Exit;
  end;
  Result.Ok := True;
end;

{ TTranscribeThread }

constructor TTranscribeThread.Create(const ASettings: TAISettings;
  const AAudioPath: string; ACallback: TTranscribeCallback);
begin
  FSettings := ASettings;
  FAudioPath := AAudioPath;
  FCallback := ACallback;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TTranscribeThread.Execute;
begin
  try
    FResult := TranscribeFileSync(FSettings, FAudioPath);
  except
    on E: Exception do
    begin
      FResult.Ok := False;
      FResult.ErrorMsg := E.ClassName + ': ' + E.Message;
    end;
  end;
  if Assigned(FCallback) then Synchronize(@DoCallback);
end;

procedure TTranscribeThread.DoCallback;
begin
  FCallback(FResult);
end;

end.
