@echo off
rem Double-click: deploy the stack, run the 15-minute live demo, then offer to tear it down.
cd /d "%~dp0"
"C:\Program Files\Git\bin\bash.exe" run.sh all
echo.
pause
