@echo off
rem Builds castsock.dll (TLS socket for Chromecast, ADB key for Fire TV) into the Reel folder. Needs Visual Studio 2022 (x64).
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%~dp0"
cl /nologo /LD /O2 /MT /W3 castsock.c ws2_32.lib secur32.lib bcrypt.lib /Fe:..\castsock.dll /Fo:%TEMP%\castsock.obj || exit /b 1
del ..\castsock.lib ..\castsock.exp 2>nul
echo built castsock.dll
