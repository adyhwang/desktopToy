@echo off
rem Repack all games in games_src/ into launcher/games/*.pck
rem Run run_m1.vbs afterwards to see the result
"%~dp0tools\godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path "%~dp0launcher" --script res://tools/make_pcks.gd
echo.
echo Done. Run run_m1.vbs to test.

