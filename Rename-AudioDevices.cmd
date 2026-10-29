@echo off
title ShowReady - audio device names in English
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Rename-AudioDevices.ps1" %*
pause
