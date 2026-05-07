@echo off
title ACE-Step 1.5 Uninstaller
color 0C

echo.
echo   ============================================
echo          ACE-Step 1.5 Uninstaller
echo   ============================================
echo.

timeout /t 1 /nobreak >nul
echo   ok one sec...
timeout /t 2 /nobreak >nul
echo.
echo   Ahhh...
timeout /t 2 /nobreak >nul
echo.
echo   Found it.. nice
timeout /t 1 /nobreak >nul
echo.
echo   Ok, and..
timeout /t 2 /nobreak >nul
echo.
echo   Deleting user profile...
timeout /t 3 /nobreak >nul

echo.
echo.
color 0A
echo   ============================================
echo          Just kidding. Your profile is fine.
echo   ============================================
echo.
color 07
echo   This will remove ACE-Step 1.5 from your system:
echo.
echo     - ACE-Step install folder (~20GB)
echo     - Desktop shortcut
echo     - Launcher settings
echo.
echo   UV and Git will NOT be removed.
echo.

set /p CONFIRM="  Type YES to confirm uninstall: "
if /i not "%CONFIRM%"=="YES" (
    echo.
    echo   Cancelled. Nothing was removed.
    echo.
    pause
    exit /b 0
)

echo.
:: Find install
set "INSTALL_PATH="
if exist "%USERPROFILE%\ACE-Step-1.5\.git" set "INSTALL_PATH=%USERPROFILE%\ACE-Step-1.5"
if exist "%USERPROFILE%\Downloads\ACE-Step-1.5\.git" if "%INSTALL_PATH%"=="" set "INSTALL_PATH=%USERPROFILE%\Downloads\ACE-Step-1.5"

if "%INSTALL_PATH%"=="" (
    echo   [!] No ACE-Step installation found.
    echo       Checked: %USERPROFILE%\ACE-Step-1.5
    echo       Checked: %USERPROFILE%\Downloads\ACE-Step-1.5
    echo.
    pause
    exit /b 1
)

echo   Found install at: %INSTALL_PATH%
echo.

:: Remove desktop shortcut
set "DESKTOP=%USERPROFILE%\Desktop"
if exist "%DESKTOP%\ACE-Step 1.5.lnk" (
    del "%DESKTOP%\ACE-Step 1.5.lnk"
    echo   [OK] Desktop shortcut removed
)

:: Kill any running acestep processes
taskkill /f /fi "WINDOWTITLE eq ACE-Step*" >nul 2>&1
powershell -Command "Get-Process python* -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*acestep*' } | Stop-Process -Force" >nul 2>&1
echo   [OK] Stopped running ACE-Step processes

:: Remove install folder
echo   Removing %INSTALL_PATH%... (this may take a minute)
rmdir /s /q "%INSTALL_PATH%"
if not exist "%INSTALL_PATH%" (
    echo   [OK] Install folder removed
) else (
    echo   [!] Some files could not be removed. Delete manually:
    echo       %INSTALL_PATH%
)

echo.
echo   ============================================
echo          Uninstall complete.
echo   ============================================
echo.
echo   ACE-Step 1.5 has been removed.
echo   UV and Git are still installed if you need them.
echo   You can delete this installer folder too.
echo.
pause
