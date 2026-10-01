@echo off
setlocal
rem Builds dist\SolastaNarrator.exe from narrator.py with PyInstaller (one file, no console).
rem One-time setup:  python -m venv %LOCALAPPDATA%\narrator_env  ^&^&  %LOCALAPPDATA%\narrator_env\Scripts\pip install edge-tts pyinstaller
cd /d "%~dp0"
set VENV=%NARRATOR_VENV%
if "%VENV%"=="" set VENV=%LOCALAPPDATA%\narrator_env
rem The base Python's own DLL folders go first on PATH, so PyInstaller bundles the DLLs its extension modules
rem were built against: a conda Python keeps ffi-8.dll (needed by _ctypes) and OpenSSL in Library\bin, and a
rem copy found elsewhere on PATH (Git's mingw64 OpenSSL) must not be picked instead.
set PYHOME=
for /f "tokens=1,* delims== " %%a in ('findstr /b /c:"home" "%VENV%\pyvenv.cfg"') do set "PYHOME=%%b"
if defined PYHOME set "PATH=%PYHOME%\Library\bin;%PYHOME%\DLLs;%PYHOME%;%PATH%"
"%VENV%\Scripts\pyinstaller.exe" --onefile --noconsole --name SolastaNarrator --distpath dist --workpath build --specpath build -y narrator.py
if errorlevel 1 exit /b 1
echo Built dist\SolastaNarrator.exe
