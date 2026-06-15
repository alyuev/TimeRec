unit uai;

// HTTP helpers (WinHTTP, no extra DLLs) + ZIP extraction + GitHub API.
// Used by the whisper.cpp installer to fetch DLL packs and models.

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Windows;

type
  TProgressEvent = procedure(BytesRead, BytesTotal: Int64) of object;

  TDownloadResult = record
    Ok: Boolean;
    ErrorMsg: string;
    HttpStatus: Integer;
    Bytes: Int64;
  end;

// Plain GET, body returned as string. For JSON / small payloads.
function HttpGetJson(const Url, ApiKey: string;
  out Response: string; out Status: Integer): Boolean;

// Streaming GET to file with progress. Follows HTTP redirects (3xx).
function HttpDownloadFile(const Url, DestPath: string;
  OnProgress: TProgressEvent): TDownloadResult;

// Extract a .zip into DestDir, flatten subfolders (we want all .dll/.exe
// alongside, not in subdirs).
function UnzipFlat(const ZipPath, DestDir: string;
  out ExtractedCount: Integer; out ErrorMsg: string): Boolean;

// Use GitHub releases/latest API to look up an asset whose name matches
// a wildcard pattern (e.g. 'whisper-cublas-*-bin-x64.zip'). Returns
// browser_download_url.
function GitHubLatestAssetUrl(const Owner, Repo, NameWildcard: string;
  out AssetUrl, AssetName: string; out ErrorMsg: string): Boolean;

function MatchesWildcard(const Name, Pattern: string): Boolean;

implementation

uses
  fpjson, jsonparser, StrUtils, Zipper;

// ---- WinHTTP bindings ----------------------------------------------------
const
  WinHttpDll = 'winhttp.dll';
  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY = 0;
  WINHTTP_FLAG_SECURE = $00800000;
  WINHTTP_QUERY_STATUS_CODE = 19;
  WINHTTP_QUERY_FLAG_NUMBER = $20000000;
  WINHTTP_QUERY_CONTENT_LENGTH = 5;
  WINHTTP_QUERY_LOCATION = 33;
  INTERNET_DEFAULT_HTTP_PORT  = 80;
  INTERNET_DEFAULT_HTTPS_PORT = 443;

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
function WinHttpSetOption(hInternet: THandle; dwOption: DWORD;
  lpBuffer: Pointer; dwBufferLength: DWORD): BOOL; stdcall;
  external WinHttpDll;

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
// Returns redirect target via OutLocation if Status is 3xx; caller can
// follow manually (WinHTTP can auto-follow but interferes with HTTPS in
// some cases).

function DoRequest(const Method, Url, ApiKey, ExtraHeaders: string;
  Stream: TStream; OnProgress: TProgressEvent;
  out Status: Integer; out OutLocation: string;
  out ErrorMsg: string): Boolean;
var
  Secure: Boolean;
  Host, Path: string;
  Port: Word;
  Session, Connect, Request: THandle;
  Flags, BytesRead, Avail, BufLen, Idx: DWORD;
  Buf: array[0..16383] of Byte;
  Total, Got: Int64;
  WAgent, WMethod, WHost, WPath, WHeaders: UnicodeString;
  AllHeaders: string;
  LocBuf: array[0..2047] of WideChar;
begin
  Result := False;
  Status := 0;
  OutLocation := '';
  ErrorMsg := '';
  Total := -1;
  Got := 0;

  SplitUrl(Url, Secure, Host, Port, Path);
  if Host = '' then begin ErrorMsg := 'empty host'; Exit; end;

  WAgent := 'TimeRec/5.0';
  Session := WinHttpOpen(PWideChar(WAgent), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
    nil, nil, 0);
  if Session = 0 then begin ErrorMsg := 'WinHttpOpen failed'; Exit; end;
  try
    WHost := UnicodeString(Host);
    Connect := WinHttpConnect(Session, PWideChar(WHost), Port, 0);
    if Connect = 0 then begin ErrorMsg := 'WinHttpConnect failed'; Exit; end;
    try
      WMethod := UnicodeString(Method);
      WPath := UnicodeString(Path);
      Flags := 0;
      if Secure then Flags := WINHTTP_FLAG_SECURE;
      Request := WinHttpOpenRequest(Connect, PWideChar(WMethod),
        PWideChar(WPath), nil, nil, nil, Flags);
      if Request = 0 then begin ErrorMsg := 'WinHttpOpenRequest failed'; Exit; end;
      try
        AllHeaders := ExtraHeaders;
        if ApiKey <> '' then
          AllHeaders := AllHeaders + 'Authorization: Bearer ' + ApiKey + #13#10;
        AllHeaders := AllHeaders + 'User-Agent: TimeRec/5.0'#13#10;
        if AllHeaders <> '' then
        begin
          WHeaders := UnicodeString(AllHeaders);
          WinHttpAddRequestHeaders(Request, PWideChar(WHeaders),
            Length(WHeaders), $A0000000);
        end;
        if not WinHttpSendRequest(Request, nil, 0, nil, 0, 0, 0) then
        begin
          ErrorMsg := 'SendRequest failed: ' + IntToStr(GetLastError);
          Exit;
        end;
        if not WinHttpReceiveResponse(Request, nil) then
        begin
          ErrorMsg := 'ReceiveResponse failed: ' + IntToStr(GetLastError);
          Exit;
        end;
        BufLen := SizeOf(DWORD);
        Idx := 0;
        WinHttpQueryHeaders(Request,
          WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
          nil, @Status, BufLen, Idx);
        if (Status >= 300) and (Status < 400) then
        begin
          BufLen := SizeOf(LocBuf);
          Idx := 0;
          if WinHttpQueryHeaders(Request, WINHTTP_QUERY_LOCATION, nil,
               @LocBuf[0], BufLen, Idx) then
            OutLocation := UTF8Encode(WideString(LocBuf));
          Result := False;
          Exit;
        end;
        // Try to get total length for progress
        BufLen := SizeOf(LocBuf);
        Idx := 0;
        if WinHttpQueryHeaders(Request, WINHTTP_QUERY_CONTENT_LENGTH, nil,
             @LocBuf[0], BufLen, Idx) then
          Total := StrToInt64Def(UTF8Encode(WideString(LocBuf)), -1);
        repeat
          Avail := 0;
          if not WinHttpQueryDataAvailable(Request, Avail) then Break;
          if Avail = 0 then Break;
          if Avail > SizeOf(Buf) then Avail := SizeOf(Buf);
          if not WinHttpReadData(Request, @Buf[0], Avail, BytesRead) then Break;
          if BytesRead = 0 then Break;
          if Stream <> nil then Stream.WriteBuffer(Buf[0], BytesRead);
          Inc(Got, BytesRead);
          if Assigned(OnProgress) then OnProgress(Got, Total);
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

function FollowRedirects(const InitialUrl, Method, ApiKey, Headers: string;
  Stream: TStream; OnProgress: TProgressEvent;
  out Status: Integer; out ErrorMsg: string): Boolean;
var
  Url, Loc: string;
  Hops: Integer;
begin
  Url := InitialUrl;
  for Hops := 0 to 9 do
  begin
    Result := DoRequest(Method, Url, ApiKey, Headers, Stream, OnProgress,
      Status, Loc, ErrorMsg);
    if Result then Exit;
    if (Status >= 300) and (Status < 400) and (Loc <> '') then
    begin
      Url := Loc;
      Continue;
    end;
    Exit;
  end;
  ErrorMsg := 'too many redirects';
  Result := False;
end;

function HttpGetJson(const Url, ApiKey: string;
  out Response: string; out Status: Integer): Boolean;
var
  S: TStringStream;
  Err: string;
begin
  S := TStringStream.Create('');
  try
    Result := FollowRedirects(Url, 'GET', ApiKey,
      'Accept: application/json'#13#10, S, nil, Status, Err);
    Response := S.DataString;
    if not Result and (Response = '') then Response := Err;
  finally
    S.Free;
  end;
end;

function HttpDownloadFile(const Url, DestPath: string;
  OnProgress: TProgressEvent): TDownloadResult;
var
  S: TFileStream;
  Err: string;
begin
  Result.Ok := False;
  Result.ErrorMsg := '';
  Result.HttpStatus := 0;
  Result.Bytes := 0;
  ForceDirectories(ExtractFilePath(DestPath));
  S := TFileStream.Create(DestPath, fmCreate);
  try
    Result.Ok := FollowRedirects(Url, 'GET', '',
      'Accept: */*'#13#10, S, OnProgress, Result.HttpStatus, Err);
    Result.Bytes := S.Size;
    if not Result.Ok then Result.ErrorMsg := Err;
  finally
    S.Free;
  end;
  if (not Result.Ok) and FileExists(DestPath) then
    SysUtils.DeleteFile(DestPath);
end;

// ---- ZIP extraction ------------------------------------------------------

function UnzipFlat(const ZipPath, DestDir: string;
  out ExtractedCount: Integer; out ErrorMsg: string): Boolean;
var
  UZ: TUnZipper;
  i: Integer;
  Names: TStringList;
  Entry: string;
  TargetName: string;
begin
  Result := False;
  ExtractedCount := 0;
  ErrorMsg := '';
  ForceDirectories(DestDir);
  Names := TStringList.Create;
  UZ := TUnZipper.Create;
  try
    try
      UZ.FileName := ZipPath;
      UZ.OutputPath := DestDir;
      // Flatten: rewrite the destination path of each entry.
      UZ.Examine;
      for i := 0 to UZ.Entries.Count - 1 do
      begin
        Entry := UZ.Entries[i].ArchiveFileName;
        if (Length(Entry) > 0) and (Entry[Length(Entry)] = '/') then Continue;
        TargetName := ExtractFileName(Entry);
        if TargetName = '' then Continue;
        UZ.Entries[i].DiskFileName := TargetName;
        Names.Add(Entry);
      end;
      UZ.UnZipFiles(Names);
      ExtractedCount := Names.Count;
      Result := True;
    except
      on E: Exception do
        ErrorMsg := E.ClassName + ': ' + E.Message;
    end;
  finally
    UZ.Free;
    Names.Free;
  end;
end;

// ---- Wildcard match (case-insensitive, supports * only) ------------------

function MatchesWildcard(const Name, Pattern: string): Boolean;
// Trivial 'A*B*C' match — case-insensitive. No '?' support.
var
  LName, LPat: string;
  P, NPos: Integer;
  Seg, Rest: string;

  function NextSeg(var Pos: Integer; const S: string; out Out: string): Boolean;
  var Star: Integer;
  begin
    Out := '';
    if Pos > Length(S) then Exit(False);
    Star := PosEx('*', S, Pos);
    if Star = 0 then begin Out := Copy(S, Pos, MaxInt); Pos := Length(S) + 1; end
    else begin Out := Copy(S, Pos, Star - Pos); Pos := Star + 1; end;
    Result := True;
  end;

begin
  LName := LowerCase(Name);
  LPat := LowerCase(Pattern);
  if Pos('*', LPat) = 0 then Exit(LName = LPat);
  P := 1;
  NPos := 1;
  // First segment must match at start (unless pattern starts with '*')
  if (Length(LPat) > 0) and (LPat[1] <> '*') then
  begin
    if not NextSeg(P, LPat, Seg) then Exit(False);
    if Copy(LName, 1, Length(Seg)) <> Seg then Exit(False);
    NPos := Length(Seg) + 1;
  end
  else if LPat[1] = '*' then
    Inc(P);
  // Middle segments: must appear in order
  while P <= Length(LPat) do
  begin
    if not NextSeg(P, LPat, Seg) then Break;
    if Seg = '' then Continue;
    NPos := PosEx(Seg, LName, NPos);
    if NPos = 0 then Exit(False);
    Inc(NPos, Length(Seg));
  end;
  // If pattern doesn't end with '*', last segment must match at the end
  if (Length(LPat) > 0) and (LPat[Length(LPat)] <> '*') then
  begin
    Rest := Seg;
    if Rest = '' then Exit(True);
    if Copy(LName, Length(LName) - Length(Rest) + 1, MaxInt) <> Rest then
      Exit(False);
  end;
  Result := True;
end;

// ---- GitHub releases API -------------------------------------------------

function GitHubLatestAssetUrl(const Owner, Repo, NameWildcard: string;
  out AssetUrl, AssetName: string; out ErrorMsg: string): Boolean;
var
  Url, Resp, N: string;
  Status, i: Integer;
  J: TJSONData;
  Arr: TJSONArray;
  Item: TJSONObject;
begin
  Result := False;
  AssetUrl := '';
  AssetName := '';
  ErrorMsg := '';
  Url := 'https://api.github.com/repos/' + Owner + '/' + Repo +
         '/releases/latest';
  if not HttpGetJson(Url, '', Resp, Status) then
  begin
    ErrorMsg := 'GitHub API: HTTP ' + IntToStr(Status) + ' ' + Copy(Resp, 1, 200);
    Exit;
  end;
  try
    J := GetJSON(Resp);
    try
      if (J is TJSONObject) and (TJSONObject(J).Find('assets') is TJSONArray) then
      begin
        Arr := TJSONArray(TJSONObject(J).Find('assets'));
        for i := 0 to Arr.Count - 1 do
          if Arr.Items[i] is TJSONObject then
          begin
            Item := TJSONObject(Arr.Items[i]);
            N := Item.Get('name', '');
            if MatchesWildcard(N, NameWildcard) then
            begin
              AssetUrl := Item.Get('browser_download_url', '');
              AssetName := N;
              if AssetUrl <> '' then Exit(True);
            end;
          end;
      end;
    finally
      J.Free;
    end;
  except
    on E: Exception do
      ErrorMsg := 'JSON parse: ' + E.Message;
  end;
  if ErrorMsg = '' then
    ErrorMsg := 'asset not found matching ' + NameWildcard;
end;

end.
