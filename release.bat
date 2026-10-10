@echo off
REM ==========================================================================
REM  JarPilot - push to GitHub and publish a release
REM  Usage:  release.bat            (uses version 1.0.0)
REM          release.bat 1.0.1      (any version)
REM  Needs:  Git for Windows. Optional: GitHub CLI (gh) for a fully automatic
REM          release; without it the release page opens in your browser.
REM ==========================================================================
setlocal EnableExtensions
cd /d "%~dp0"

set "REPO=gauravgupta0612/jatpilot"
set "VERSION=%~1"
if "%VERSION%"=="" set "VERSION=1.0.0"
set "TAG=v%VERSION%"
set "VSIX=vscode-extension\jarpilot-%VERSION%.vsix"
set "PLUGIN=jarpilot-%VERSION%.plugin"

echo.
echo === JarPilot release %TAG% to https://github.com/%REPO% ===
echo.

where git >nul 2>&1 || (echo [ERROR] Git is not installed. Get it from https://git-scm.com & goto :fail)

if not exist "%VSIX%"   (echo [ERROR] Missing %VSIX% & goto :fail)
if not exist "%PLUGIN%" (echo [ERROR] Missing %PLUGIN% & goto :fail)

REM --- commit anything new, as gauravgupta0612 -----------------------------
git config user.name  "gauravgupta0612"
git config user.email "gauravgupta0612@users.noreply.github.com"
git add -A
git diff --cached --quiet || git commit -m "Release %TAG%" || goto :fail

REM --- push branch -----------------------------------------------------------
echo [1/3] Pushing main ...
git push -u origin main || (echo [ERROR] Push failed - check your GitHub sign-in. & goto :fail)

REM --- tag ------------------------------------------------------------------
echo [2/3] Tagging %TAG% ...
git rev-parse -q --verify "refs/tags/%TAG%" >nul 2>&1 || git tag -a "%TAG%" -m "JarPilot %TAG%"
git push origin "%TAG%" || goto :fail

REM --- release --------------------------------------------------------------
echo [3/3] Creating GitHub release %TAG% ...
where gh >nul 2>&1
if errorlevel 1 goto :manual

gh auth status >nul 2>&1 || gh auth login --web || goto :manual
gh release view "%TAG%" --repo "%REPO%" >nul 2>&1
if not errorlevel 1 (
  echo Release %TAG% exists - updating assets ...
  gh release upload "%TAG%" "%VSIX%" "%PLUGIN%" --repo "%REPO%" --clobber || goto :fail
) else (
  gh release create "%TAG%" "%VSIX%" "%PLUGIN%" --repo "%REPO%" --title "JarPilot %TAG%" --notes-file RELEASE_NOTES.md || goto :fail
)
echo.
echo DONE: https://github.com/%REPO%/releases/tag/%TAG%
goto :end

:manual
echo.
echo GitHub CLI not available - opening the release page in your browser.
echo Attach these two files, then click "Publish release":
echo    %CD%\%VSIX%
echo    %CD%\%PLUGIN%
start "" "https://github.com/%REPO%/releases/new?tag=%TAG%&title=JarPilot%%20%TAG%"
start "" explorer /select,"%CD%\%PLUGIN%"
goto :end

:fail
echo.
echo *** Release FAILED ***
pause
exit /b 1

:end
echo.
pause
endlocal
