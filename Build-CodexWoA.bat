@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "POWERSHELL_EXE=pwsh.exe"

where pwsh.exe >nul 2>nul
if errorlevel 1 set "POWERSHELL_EXE=powershell.exe"

"%POWERSHELL_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Build-CodexWoA.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

if not "%EXITCODE%"=="0" (
    echo.
    echo Build-CodexWoA.ps1 failed with exit code %EXITCODE%.
)

echo.
pause
exit /b %EXITCODE%
