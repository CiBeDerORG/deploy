@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "WSL_EXE=%SystemRoot%\System32\wsl.exe"

if not exist "%WSL_EXE%" (
    echo [ERROR] Windows Subsystem for Linux ^(wsl.exe^) was not found.
    echo Install WSL from an elevated terminal: wsl --install -d Ubuntu
    exit /b 1
)

rem Prefer a normal Linux distribution; Docker Desktop's internal distro has no bash.
rem Set DEPLOY_WSL_DISTRO to override automatic selection.
set "WSL_DISTRO=%DEPLOY_WSL_DISTRO%"
set "WSL_DISTRO_FILE=%TEMP%\deploy-wsl-distro-%RANDOM%-%RANDOM%.tmp"
if not defined WSL_DISTRO (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$d = @(wsl.exe --list --quiet | ForEach-Object { ($_ -replace '[\x00-\x1f]', '').Trim() } | Where-Object { $_ -and $_ -notmatch '^docker-desktop' }); if ($d.Count -gt 0) { [System.IO.File]::WriteAllText($env:WSL_DISTRO_FILE, ([string]$d[0] + [Environment]::NewLine), [System.Text.Encoding]::ASCII) }"
    if exist "%WSL_DISTRO_FILE%" (
        set /p "WSL_DISTRO=" < "%WSL_DISTRO_FILE%"
        del /q "%WSL_DISTRO_FILE%"
    )
)

if not defined WSL_DISTRO (
    echo [ERROR] No regular Linux WSL distribution was found.
    echo Docker Desktop's internal distro cannot run this deployment script.
    echo Install Ubuntu with: wsl --install -d Ubuntu
    echo Then restart this command, or set DEPLOY_WSL_DISTRO to your distro name.
    "%WSL_EXE%" --list --verbose
    exit /b 1
)

echo [INFO] WSL distribution: "%WSL_DISTRO%"
"%WSL_EXE%" --distribution "%WSL_DISTRO%" --exec true >nul 2>&1
if errorlevel 1 (
    echo [ERROR] WSL distribution "%WSL_DISTRO%" could not be started.
    echo Run: wsl --list --verbose
    echo To choose another distribution, set DEPLOY_WSL_DISTRO to its exact name.
    exit /b 1
)

"%WSL_EXE%" --distribution "%WSL_DISTRO%" --exec bash -lc "command -v bash" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] WSL distribution "%WSL_DISTRO%" does not have bash available.
    echo Install/use Ubuntu or another Linux distribution with bash.
    exit /b 1
)

if not exist "%~dp0deploy.sh" (
    echo [ERROR] deploy.sh was not found beside this launcher.
    echo Place deploy.bat in the root of the deploy repository.
    exit /b 1
)

set "WSL_DIR="
set "WSL_PATH_FILE=%TEMP%\deploy-wslpath-%RANDOM%-%RANDOM%.tmp"
"%WSL_EXE%" --distribution "%WSL_DISTRO%" --exec wslpath -u "%~dp0." > "%WSL_PATH_FILE%"
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
"%WSL_EXE%" --distribution "%WSL_DISTRO%" --cd "%WSL_DIR%" --exec test -f ./deploy.sh >nul 2>&1
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

"%WSL_EXE%" --distribution "%WSL_DISTRO%" --cd "%WSL_DIR%" --exec bash ./deploy.sh %*
set "DEPLOY_EXIT_CODE=%ERRORLEVEL%"

if not "%DEPLOY_EXIT_CODE%"=="0" (
    echo.
    echo [ERROR] deploy.sh exited with code %DEPLOY_EXIT_CODE%.
) else (
    echo.
    echo [OK] deploy.sh completed successfully.
)

exit /b %DEPLOY_EXIT_CODE%
