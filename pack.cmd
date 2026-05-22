@echo off
rem Post-build UPX packer. Gracefully no-ops if upx is not installed.
setlocal enabledelayedexpansion
set "UPXBIN="
where upx >nul 2>&1 && set "UPXBIN=upx"
if not defined UPXBIN if exist "%LOCALAPPDATA%\Microsoft\WinGet\Links\upx.exe" set "UPXBIN=%LOCALAPPDATA%\Microsoft\WinGet\Links\upx.exe"
if not defined UPXBIN (
  for /f "delims=" %%f in ('dir /s /b "%LOCALAPPDATA%\Microsoft\WinGet\Packages\upx.exe" 2^>nul') do (
    if not defined UPXBIN set "UPXBIN=%%f"
  )
)
if not defined UPXBIN (
  echo [pack.cmd] upx not found - install with: winget install UPX.UPX
  exit /b 0
)
echo [pack.cmd] Packing with: !UPXBIN!
"!UPXBIN!" --best --lzma "%~1"
exit /b 0
