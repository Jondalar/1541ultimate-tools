@echo off
setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "BASH_EXE="

where bash >nul 2>&1 && set "BASH_EXE=bash"
if not defined BASH_EXE if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH_EXE if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH_EXE=%ProgramFiles(x86)%\Git\bin\bash.exe"

if defined BASH_EXE (
    "%BASH_EXE%" "%SCRIPT_DIR%build" %*
    exit /b %ERRORLEVEL%
)

where wsl >nul 2>&1
if %ERRORLEVEL%==0 (
    for /f "usebackq delims=" %%I in (`wsl wslpath "%SCRIPT_DIR%build"`) do set "WSL_SCRIPT=%%I"
    wsl bash "!WSL_SCRIPT!" %*
    exit /b %ERRORLEVEL%
)

echo Unable to find bash or wsl.exe. Install Git Bash or WSL, then run build through that shell.
exit /b 3