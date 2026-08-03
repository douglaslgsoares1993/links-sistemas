@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0CHECAR_LINKS.ps1"
if errorlevel 1 echo.&echo Falha ao concluir a verificacao.
echo.
pause

