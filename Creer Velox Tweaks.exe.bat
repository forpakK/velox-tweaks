@echo off
title Creation de Velox Tweaks.exe
cd /d "%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo Compilateur .NET introuvable sur ce PC.
  pause
  exit /b 1
)
echo Creation de Velox Tweaks.exe...
"%CSC%" /nologo /target:winexe /codepage:65001 /out:"Velox Tweaks.exe" /win32icon:build\velox.ico /win32manifest:build\app.manifest /r:System.Windows.Forms.dll build\Launcher.cs
if exist "Velox Tweaks.exe" (
  echo.
  echo OK ! "Velox Tweaks.exe" est pret dans ce dossier.
  echo Double-clique dessus pour lancer Velox.
) else (
  echo.
  echo ECHEC : envoie une capture de cette fenetre.
)
echo.
pause
