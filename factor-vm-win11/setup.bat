@echo off
REM ============================================================================
REM  setup.bat - Wrapper dla setup.ps1 (STRUCTURA FACTOR VM Win11)
REM  Uruchamia setup.ps1 z podanymi parametrami.
REM
REM  Usage:
REM    setup.bat -Client sawaryn -DeployKeyPath C:\path\to\deploy_key
REM    setup.bat -Client sawaryn -MediaPath "C:\Users\premek\OneDrive\STRUCTURA\media\"
REM ============================================================================

REM Sprawdz czy PowerShell jest dostepny
where pwsh >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    set "PS_CMD=pwsh"
) else (
    set "PS_CMD=powershell"
)

REM Uruchom setup.ps1 z przekazanymi parametrami
%PS_CMD% -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*

REM Przekaz exit code
exit /b %ERRORLEVEL%