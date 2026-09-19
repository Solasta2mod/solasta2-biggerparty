@echo off
setlocal
rem Builds dist\SolastaNarrator.exe from narrator.py with PyInstaller (one file, no console).
rem One-time setup:  python -m venv %LOCALAPPDATA%\narrator_env  ^&^&  %LOCALAPPDATA%\narrator_env\Scripts\pip install edge-tts pyinstaller
cd /d "%~dp0"
set VENV=%NARRATOR_VENV%
if "%VENV%"=="" set VENV=%LOCALAPPDATA%\narrator_env
"%VENV%\Scripts\pyinstaller.exe" --onefile --noconsole --name SolastaNarrator --distpath dist --workpath build --specpath build -y narrator.py
if errorlevel 1 exit /b 1
echo Built dist\SolastaNarrator.exe
