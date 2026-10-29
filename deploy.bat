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
for /f "usebackq delims=" %%I in (`"%WSL_EXE%" --exec wslpath -a "%~dp0." 2^>nul`) do set "WSL_DIR=%%I"

if not defined WSL_DIR (
    echo [ERROR] Could not convert the repository path to a WSL path.
    echo Make sure the drive containing this repository is mounted in WSL.
    exit /b 1
)

echo.
echo [INFO] Repository: %WSL_DIR%
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
