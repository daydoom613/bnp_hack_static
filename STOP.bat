@echo off
rem Double-click: tear the AWS stack down (stops billing) and stop Grafana.
cd /d "%~dp0"
"C:\Program Files\Git\bin\bash.exe" run.sh down
echo.
pause
