@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "WSL_EXE=%SystemRoot%\System32\wsl.exe"

if not exist "%WSL_EXE%" (
    echo [ERROR] Windows Subsystem for Linux ^(wsl.exe^) was not found.
    echo Install WSL from an elevated terminal: wsl --install -d Ubuntu
    exit /b 1
)

rem Verify that a default WSL distribution can execute Linux commands.
"%WSL_EXE%" --exec true >nul 2>&1
if errorlevel 1 (
    echo [ERROR] No usable default WSL distribution is available.
    echo Open an elevated PowerShell and run: wsl --install -d Ubuntu
    echo Restart Windows if requested, then finish the Ubuntu first-run setup.
    exit /b 1
)

if not exist "%~dp0deploy.sh" (
    echo [ERROR] deploy.sh was not found beside this launcher.
    echo Place deploy.bat in the root of the deploy repository.
    exit /b 1
)

set "WSL_DIR="
set "WSL_PATH_FILE=%TEMP%\deploy-wslpath-%RANDOM%-%RANDOM%.tmp"
"%WSL_EXE%" --exec wslpath -u "%~dp0." > "%WSL_PATH_FILE%"
if errorlevel 1 (
    echo [ERROR] wslpath failed to convert the repository path.
    echo Windows path: "%~dp0"
    if exist "%WSL_PATH_FILE%" type "%WSL_PATH_FILE%"
    if exist "%WSL_PATH_FILE%" del /q "%WSL_PATH_FILE%"
    exit /b 1
)
set /p "WSL_DIR=" < "%WSL_PATH_FILE%"
del /q "%WSL_PATH_FILE%"

if not defined WSL_DIR (
    echo [ERROR] Could not convert the repository path to a WSL path.
    echo Windows path: "%~dp0"
    echo Check that WSL has a default Linux distribution and that wslpath is available.
    echo If P: is a mapped or network drive, WSL may not be able to access it automatically.
    exit /b 1
)

rem Confirm the translated path points to this repository inside WSL.
"%WSL_EXE%" --cd "%WSL_DIR%" --exec test -f ./deploy.sh >nul 2>&1
if errorlevel 1 (
    echo [ERROR] WSL resolved the path but cannot find deploy.sh at that location.
    echo Windows path: "%~dp0"
    echo WSL path: "%WSL_DIR%"
    echo If this is a mapped/network drive such as P:, move the repository to a local drive
    echo accessible from WSL, or configure/mount that drive inside your WSL distribution.
    exit /b 1
)

echo.
echo [INFO] Repository path resolved: "%WSL_DIR%"
echo [INFO] Running the existing Linux deploy.sh inside WSL.
echo [INFO] Docker commands require Docker Engine in WSL or Docker Desktop WSL integration.
echo [INFO] "mihomo host" requires systemd enabled in the WSL distribution.
echo.

"%WSL_EXE%" --cd "%WSL_DIR%" --exec bash ./deploy.sh %*
set "DEPLOY_EXIT_CODE=%ERRORLEVEL%"

if not "%DEPLOY_EXIT_CODE%"=="0" (
    echo.
    echo [ERROR] deploy.sh exited with code %DEPLOY_EXIT_CODE%.
) else (
    echo.
    echo [OK] deploy.sh completed successfully.
)

exit /b %DEPLOY_EXIT_CODE%
