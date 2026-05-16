@echo off
REM ============================================================================
REM open-git-bash.bat - double-click to open a Git Bash shell in the project
REM root, where the deployment scripts can be run on Windows. NO WSL required.
REM
REM It looks for a bash shell in this order:
REM   1. PortableGit bundled inside  share-access\PortableGit\   (zero-install)
REM   2. An installed "Git for Windows"
REM If neither is found, it shows how to get one.
REM
REM In the shell that opens, run e.g.:
REM     bash share-access/setup.sh            (first-time setup)
REM     ./scripts/deploy.sh 1.20.4
REM     ./scripts/server-start.sh 1.20.4
REM ============================================================================
setlocal

REM Project root = the folder that contains this share-access folder.
for %%I in ("%~dp0..") do set "PROJECT_DIR=%%~fI"

set "GITBASH="

REM 1. Bundled PortableGit (zero-install) - the owner can extract PortableGit
REM    into share-access\PortableGit\ so the recipient installs nothing at all.
if exist "%~dp0PortableGit\git-bash.exe" set "GITBASH=%~dp0PortableGit\git-bash.exe"

REM 2. An installed Git for Windows, in the usual locations.
if not defined GITBASH for %%P in (
  "%ProgramFiles%\Git\git-bash.exe"
  "%ProgramFiles(x86)%\Git\git-bash.exe"
  "%LocalAppData%\Programs\Git\git-bash.exe"
) do if not defined GITBASH if exist "%%~P" set "GITBASH=%%~P"

if defined GITBASH (
  echo Opening Git Bash in: %PROJECT_DIR%
  start "" "%GITBASH%" --cd="%PROJECT_DIR%"
  exit /b 0
)

echo.
echo  No bash shell found. These scripts need Git Bash ^(no WSL required^).
echo.
echo  Easiest fix - install "Git for Windows". It is a normal per-user
echo  installer: no administrator rights, no reboot.
echo     https://git-scm.com/download/win
echo.
echo  Zero-install alternative - ask whoever sent you this project to extract
echo  "PortableGit" into the  share-access\PortableGit\  folder before zipping.
echo.
echo  Then double-click this file again.
echo.
pause
exit /b 1
