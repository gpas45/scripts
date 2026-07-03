@echo off
chcp 65001 >nul
title Ochistka kesha 1C

echo Zakryvayu processy 1C...
taskkill /F /IM 1cv8.exe   >nul 2>&1
taskkill /F /IM 1cv8c.exe  >nul 2>&1
taskkill /F /IM 1cv8s.exe  >nul 2>&1

echo Chishchu kesh...
if exist "%APPDATA%\1C\1cv8"      rd /s /q "%APPDATA%\1C\1cv8"
if exist "%LOCALAPPDATA%\1C\1cv8" rd /s /q "%LOCALAPPDATA%\1C\1cv8"

echo.
echo Gotovo. Kesh peresozdastsya pri sleduyushchem zapuske 1C.
pause
