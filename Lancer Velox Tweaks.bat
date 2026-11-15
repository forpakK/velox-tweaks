@echo off
title Velox Tweaks
cd /d "%~dp0"
echo Velox Tweaks demarre... (garde cette fenetre ouverte)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0VeloxTweaks.ps1"
if errorlevel 1 pause
