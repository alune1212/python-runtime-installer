@echo off
setlocal
set "RUNTIME_ROOT=%LOCALAPPDATA%\Programs\Python Runtime Installer"
if not exist "%RUNTIME_ROOT%\venv\Scripts\activate.bat" (
  echo Managed Python environment was not found.
  echo Re-run Python Runtime Installer to repair the environment.
  exit /b 1
)
call "%RUNTIME_ROOT%\venv\Scripts\activate.bat"
title Python Runtime Installer Environment
cmd /k
