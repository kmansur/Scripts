
## 5. Executar-Coleta.bat comentado

```bat
@echo off
title Coleta de Inventario - NetTech

REM Entra na pasta onde o BAT esta localizado.
REM Isso garante que o script rode a partir do pendrive.
cd /d "%~dp0"

echo.
echo ==========================================
echo   Coleta de Inventario - NetTech
echo ==========================================
echo.

REM Solicita o numero de inventario ao operador.
set /p INV=Digite o numero do inventario / FA: 

REM Executa o PowerShell sem depender da politica local de execucao.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Coleta-Inventario.ps1" -i "%INV%"

echo.
echo Pressione qualquer tecla para sair...
pause >nul