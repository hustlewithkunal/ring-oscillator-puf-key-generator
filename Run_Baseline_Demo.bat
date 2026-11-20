@echo off
setlocal
title RO-PUF demo - baseline RO-PUF
rem ===========================================================================
rem Double-click: on-board demo of the RO-PUF key generator with the BASELINE
rem RO-PUF (plain ring oscillators, fixed comparison pairs).
rem   1. finds Vivado and Python
rem   2. checks build\top_soc.bit / .ltx, builds them if missing (15-20 min)
rem   3. programs the board and runs scripts\hw\soc_demo.tcl base 100:
rem      enrolment + lock, authentication, impostors, 100 reconstructions
rem   4. prints a PASS/FAIL summary; logs in build\logs, results in build\runs
rem ===========================================================================
set "MODE=base"
set "NAME=baseline"
set "N=100"
goto :main

:main
call "%~dp0scripts\win\common.bat" setup || goto :fail
echo  Before you start:
echo    - Zybo Z7-10 connected by USB ^(PROG/UART port^) and powered on
echo    - ALL switches SW0..SW3 OFF ^(SW3 ON = enrolment locked, the emulated fuse^)
echo    - no Vivado Hardware Manager open ^(it would hold the JTAG cable^)
echo.
call "%~dp0scripts\win\common.bat" bitstream || goto :fail
echo.
set "PUF_OUT_DIR=%ROOT%\build\runs\%TS%_%NAME%"
set "RUNLOG=%LOGDIR%\demo_%MODE%_%TS%.log"
echo [..] Programming the board and running the %NAME% demo ^(about 1 minute^)
echo      Vivado log : %RUNLOG%
echo      Results    : %PUF_OUT_DIR%
echo.
call "%VIVADO%" -mode batch -nojournal -log "%RUNLOG%" -source "%ROOT%\scripts\hw\soc_demo.tcl" -tclargs %MODE% %N%
call "%~dp0scripts\win\common.bat" checkdemo "%PUF_OUT_DIR%\demo_%MODE%.txt" "%RUNLOG%" %N% || goto :fail
echo.
echo Logs   : %RUNLOG%
echo Results: %PUF_OUT_DIR%
echo.
pause
exit /b 0

:fail
echo.
echo *** The %NAME% demo did NOT complete successfully - see the messages above. ***
echo.
pause
exit /b 1
