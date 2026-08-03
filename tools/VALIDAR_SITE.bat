@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VALIDAR_SITE.ps1"
set "resultado=%errorlevel%"
echo.
if not "%resultado%"=="0" echo VALIDACAO REPROVADA. Nao publique este estado.
pause
exit /b %resultado%

