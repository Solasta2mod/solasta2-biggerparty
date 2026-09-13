@echo off
setlocal
rem Builds ..\dist\BiggerParty-Installer.exe. Run gen_payload.py first (stages payload\ and generates payload.rc/.h).
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
cd /d "%~dp0"
if not exist build mkdir build
rc /nologo /fo build\payload.res payload.rc
if errorlevel 1 exit /b 1
cl /nologo /O2 /W3 /EHsc /std:c++17 /D_CRT_SECURE_NO_WARNINGS installer.cpp /Fo:build\ /Fe:..\dist\BiggerParty-Installer.exe /link build\payload.res /SUBSYSTEM:CONSOLE
if errorlevel 1 exit /b 1
echo Built ..\dist\BiggerParty-Installer.exe
