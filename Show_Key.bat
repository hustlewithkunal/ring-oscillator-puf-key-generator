@echo off
setlocal
title RO-PUF key generator - show the key in the FPGA
rem ===========================================================================
rem Double-click: generate the key on the board and show it.
rem   1. finds Vivado and Python, checks numpy
rem   2. checks build\top_soc.bit / .ltx, builds them if missing (15-20 min)
rem   3. asks baseline or configurable RO-PUF (default baseline after 15 s)
rem   4. scripts\hw\soc_key.tcl: enrols device 0 with host-chosen BCH messages,
rem      reconstructs, collects MAC tags before and after a SoC reset, tries the
rem      other two RO arrays
rem   5. scripts\show_key.py: recomputes the key from the enrolment secret and the
rem      helper data with the golden model, and proves it is the key inside the
rem      chip: the FPGA's KCV and MAC tags must match it.
rem The FPGA has no command that outputs the key; it never leaves the chip.
rem ===========================================================================
call "%~dp0scripts\win\common.bat" setup || goto :fail
if not defined PY (
    echo [ERROR] Python 3 is needed to show the key. Install Python 3.8 or newer.
    goto :fail
)
%PY% -c "import numpy" >nul 2>&1
if errorlevel 1 (
    echo [..] numpy is missing, installing it: %PY% -m pip install -r requirements.txt
    %PY% -m pip install -r "%ROOT%\requirements.txt"
    %PY% -c "import numpy" >nul 2>&1 || (echo [ERROR] numpy could not be installed.& goto :fail)
)
echo  Before you start:
echo    - Zybo Z7-10 connected by USB ^(PROG/UART port^) and powered on
echo    - ALL switches SW0..SW3 OFF ^(SW3 ON = enrolment locked, the emulated fuse^)
echo    - no Vivado Hardware Manager open ^(it would hold the JTAG cable^)
echo.
call "%~dp0scripts\win\common.bat" bitstream || goto :fail
echo.
choice /c BC /t 15 /d B /m "Which RO-PUF?  B = baseline,  C = configurable "
if errorlevel 2 (set "MODE=cfg" & set "NAME=configurable") else (set "MODE=base" & set "NAME=baseline")
echo.
set "PUF_OUT_DIR=%ROOT%\build\runs\%TS%_key_%NAME%"
set "RUNLOG=%LOGDIR%\key_%MODE%_%TS%.log"
echo [..] Programming the board and generating the key, %NAME% RO-PUF ^(about 30 s^)
echo      Vivado log : %RUNLOG%
echo      Results    : %PUF_OUT_DIR%
echo.
call "%VIVADO%" -mode batch -nojournal -log "%RUNLOG%" -source "%ROOT%\scripts\hw\soc_key.tcl" -tclargs %MODE%
if not exist "%PUF_OUT_DIR%\key_%MODE%.txt" goto :hwfail
findstr /l /c:"KEY_SESSION_DONE" "%RUNLOG%" >nul || goto :hwfail
%PY% "%ROOT%\scripts\show_key.py" "%PUF_OUT_DIR%\key_%MODE%.txt" > "%PUF_OUT_DIR%\key_%MODE%_report.txt" 2>&1
set "RC=%errorlevel%"
type "%PUF_OUT_DIR%\key_%MODE%_report.txt"
echo.
echo Report : %PUF_OUT_DIR%\key_%MODE%_report.txt
echo Logs   : %RUNLOG%
echo.
if not "%RC%"=="0" goto :fail
pause
exit /b 0

:hwfail
echo.
echo [FAIL] The key session did not run to the end.
call "%~dp0scripts\win\common.bat" hwerror "%RUNLOG%"

:fail
echo.
echo *** Showing the key did NOT complete successfully - see the messages above. ***
echo.
pause
exit /b 1
