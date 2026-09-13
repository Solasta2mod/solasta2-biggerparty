@echo off
setlocal
rem Builds dist\version.dll (the BiggerParty patcher) with MSVC Build Tools 2022.
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 exit /b 1
cd /d "%~dp0"
if not exist build mkdir build
if not exist dist mkdir dist
cl /nologo /O2 /W3 /EHsc /std:c++17 /D_CRT_SECURE_NO_WARNINGS /LD src\version_proxy.cpp /Fo:build\ /Fe:dist\version.dll /link /OPT:REF
if errorlevel 1 exit /b 1
del /q dist\version.exp dist\version.lib 2>nul
echo Built dist\version.dll
