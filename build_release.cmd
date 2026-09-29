@echo off
rem DesktopToy release build with platform selection
rem Usage: build_release.cmd [win] [x64] [arm64] [web] [all]
rem   No arguments -> interactive platform menu
rem Output: publish\release\win\         (zip to ship, double-click DesktopToy.exe)
rem         publish\release\linux_x64\   (zip to ship, run DesktopToy)
rem         publish\release\linux_arm64\ (zip to ship, run DesktopToy)
rem         publish\release\web\         (deploy on any static HTTP server, open dt.html)
rem Launch: in-app desktop snapshot at startup (window starts minimized), no launcher scripts needed
rem Fallback: put wallpaper.png/jpg next to the binary for environments where screen capture fails
rem Language files (launcher Language\ + per-game games_src\<id>\language\ -> games\<id>\) are copied in every assemble step
setlocal
set ROOT=%~dp0
set GODOT=%ROOT%tools\godot\Godot_v4.7.2-stable_win64_console.exe
set OUT=%ROOT%publish\release\win
set OUT_X64=%ROOT%publish\release\linux_x64
set OUT_ARM=%ROOT%publish\release\linux_arm64
set OUT_WEB=%ROOT%publish\release\web

rem ---- select platforms ----
set DO_WIN=
set DO_X64=
set DO_ARM=
set DO_WEB=
if not "%~1"=="" goto :parse
echo Select platforms to build:
echo   1 = Windows
echo   2 = Linux x64
echo   3 = Linux arm64
echo   4 = Web
echo   a = All
set /p SEL=Choose (e.g. 1 3 / 1,3 / a):
if "%SEL%"=="" (echo No platform selected.& exit /b 1)
echo %SEL%|find /i "a" >nul && (set DO_WIN=1& set DO_X64=1& set DO_ARM=1& set DO_WEB=1)
if not "%SEL:1=%"=="%SEL%" set DO_WIN=1
if not "%SEL:2=%"=="%SEL%" set DO_X64=1
if not "%SEL:3=%"=="%SEL%" set DO_ARM=1
if not "%SEL:4=%"=="%SEL%" set DO_WEB=1
goto :picked
:parse
if "%~1"=="" goto :picked
if /i "%~1"=="win" set DO_WIN=1
if /i "%~1"=="x64" set DO_X64=1
if /i "%~1"=="arm64" set DO_ARM=1
if /i "%~1"=="web" set DO_WEB=1
if /i "%~1"=="all" (set DO_WIN=1& set DO_X64=1& set DO_ARM=1& set DO_WEB=1)
shift
goto :parse
:picked
set BUILDING=
if defined DO_WIN set BUILDING=%BUILDING% Windows
if defined DO_X64 set BUILDING=%BUILDING% Linux_x64
if defined DO_ARM set BUILDING=%BUILDING% Linux_arm64
if defined DO_WEB set BUILDING=%BUILDING% Web
if "%BUILDING%"=="" (echo Unknown platform. Use: win x64 arm64 web all& exit /b 1)
echo Building:%BUILDING%

echo [prep] Repacking game pcks ...
"%GODOT%" --headless --path "%ROOT%launcher" --script res://tools/make_pcks.gd
if errorlevel 1 goto :err

if defined DO_WIN call :win
if errorlevel 1 goto :err
if defined DO_X64 call :x64
if errorlevel 1 goto :err
if defined DO_ARM call :arm
if errorlevel 1 goto :err
if defined DO_WEB call :web
if errorlevel 1 goto :err

echo.
echo Done. Distributable folders (double-click the binary to play):
if defined DO_WIN echo   Windows:     %OUT%      (DesktopToy.exe + DesktopToy.pck + games\ + Language\)
if defined DO_X64 echo   Linux x64:   %OUT_X64%  (DesktopToy + DesktopToy.pck + games\ + Language\ + icon.png + install.sh)
if defined DO_ARM echo   Linux arm64: %OUT_ARM%  (DesktopToy + DesktopToy.pck + games\ + Language\ + icon.png + install.sh)
if defined DO_WEB echo   Web:         %OUT_WEB%  (dt.html + games\ + dt.wasm.gz - serve the whole folder via any static HTTP server)
goto :eof

:win
echo [Windows] Exporting DesktopToy.exe ...
if not exist "%OUT%\games" mkdir "%OUT%\games"
"%GODOT%" --headless --path "%ROOT%launcher" --export-release "Windows Desktop" "%OUT%\DesktopToy.exe"
if errorlevel 1 goto :err
echo [Windows] Assembling distributable ...
copy /y "%ROOT%launcher\games\*.pck" "%OUT%\games\" >nul
call :copy_lang "%OUT%"
if exist "%ROOT%tools\upx\upx.exe" (
  "%ROOT%tools\upx\upx.exe" --best --lzma "%OUT%\DesktopToy.exe" >nul
) else (
  echo   skip upx: tools\upx\upx.exe not found
)
goto :eof

:x64
echo [Linux x64] Exporting DesktopToy ...
if not exist "%OUT_X64%\games" mkdir "%OUT_X64%\games"
"%GODOT%" --headless --path "%ROOT%launcher" --export-release "Linux (x86_64)" "%OUT_X64%\DesktopToy"
if errorlevel 1 goto :err
echo [Linux x64] Assembling distributable ...
copy /y "%ROOT%launcher\games\*.pck" "%OUT_X64%\games\" >nul
call :copy_lang "%OUT_X64%"
copy /y "%ROOT%launcher\icon_app.png" "%OUT_X64%\icon.png" >nul
copy /y "%ROOT%launcher\tools\install.sh" "%OUT_X64%\" >nul
if exist "%ROOT%tools\upx\upx.exe" (
  "%ROOT%tools\upx\upx.exe" --best --lzma "%OUT_X64%\DesktopToy" >nul
) else (
  echo   skip upx: tools\upx\upx.exe not found
)
goto :eof

:arm
echo [Linux arm64] Exporting DesktopToy ...
if not exist "%OUT_ARM%\games" mkdir "%OUT_ARM%\games"
"%GODOT%" --headless --path "%ROOT%launcher" --export-release "Linux (arm64)" "%OUT_ARM%\DesktopToy"
if errorlevel 1 goto :err
echo [Linux arm64] Assembling distributable ...
copy /y "%ROOT%launcher\games\*.pck" "%OUT_ARM%\games\" >nul
call :copy_lang "%OUT_ARM%"
copy /y "%ROOT%launcher\icon_app.png" "%OUT_ARM%\icon.png" >nul
copy /y "%ROOT%launcher\tools\install.sh" "%OUT_ARM%\" >nul
if exist "%ROOT%tools\upx\upx.exe" (
  "%ROOT%tools\upx\upx.exe" --best --lzma "%OUT_ARM%\DesktopToy" >nul
) else (
  echo   skip upx: tools\upx\upx.exe not found
)
goto :eof

:web
echo [Web] Preparing index.txt + version stamp + per-game language json ...
rem Must exist BEFORE the export: the Web preset packs them into the main pck via include_filter
if not exist "%OUT_WEB%" mkdir "%OUT_WEB%"
for /d %%G in ("%ROOT%games_src\*") do (
  if not exist "%ROOT%launcher\games\%%~nxG" mkdir "%ROOT%launcher\games\%%~nxG"
  copy /y "%%G\language\*.json" "%ROOT%launcher\games\%%~nxG\" >nul
)
dir /b "%ROOT%launcher\games\*.pck" > "%ROOT%launcher\games\index.txt"
rem version stamp: the web launcher caches downloaded pcks in user:// until this changes
powershell -NoProfile -Command "Get-Date -Format o | Set-Content -Encoding ASCII '%ROOT%launcher\games\version.txt'"
echo [Web] Exporting dt.html ...
"%GODOT%" --headless --path "%ROOT%launcher" --export-release "Web" "%OUT_WEB%\dt.html"
if errorlevel 1 goto :err
echo [Web] Deploying game packs + gzipping dt.wasm ...
rem game pcks ship as separate files next to dt.html (launcher downloads them at startup)
if not exist "%OUT_WEB%\games" mkdir "%OUT_WEB%\games"
copy /y "%ROOT%launcher\games\*.pck" "%OUT_WEB%\games\" >nul
rem dt.wasm (~37MB) exceeds the 25MB per-file limit: gzip it, the head_include
rem fetch shim in dt.html decompresses it via DecompressionStream at load time
powershell -NoProfile -Command "$i='%OUT_WEB%\dt.wasm';$o='%OUT_WEB%\dt.wasm.gz';$fs=[IO.File]::OpenRead($i);$gz=[IO.File]::Create($o);$gs=New-Object IO.Compression.GZipStream($gz,[IO.Compression.CompressionLevel]::Optimal);$fs.CopyTo($gs);$gs.Close();$fs.Close()"
if errorlevel 1 goto :err
del "%OUT_WEB%\dt.wasm"
goto :eof

:copy_lang
rem %1 = target dir: launcher UI languages + per-game language json (games\<id>\<code>.json)
if not exist "%~1\Language" mkdir "%~1\Language"
copy /y "%ROOT%launcher\Language\*.json" "%~1\Language\" >nul
for /d %%G in ("%ROOT%games_src\*") do (
  if not exist "%~1\games\%%~nxG" mkdir "%~1\games\%%~nxG"
  copy /y "%%G\language\*.json" "%~1\games\%%~nxG\" >nul
)
goto :eof

:err
echo BUILD FAILED.
exit /b 1
