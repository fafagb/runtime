@rem Licensed to the .NET Foundation under one or more agreements.
@rem The .NET Foundation licenses this file to you under the MIT license.
@rem See the LICENSE file in the project root for more information.

@if not defined _echo echo off

setlocal ENABLEDELAYEDEXPANSION
  set ERRORLEVEL=
  set DOTNET_MULTILEVEL_LOOKUP=0
  set UseSharedCompilation=false

  set BENCHVIEW_RUN_TYPE=local
  set CORECLR_REPO=%CD%
  set LV_SANDBOX_DIR=%CORECLR_REPO%\bin\sandbox
  set LV_SANDBOX_OUTPUT_DIR=%LV_SANDBOX_DIR%\Logs
  set TEST_FILE_EXT=exe
  set TEST_ARCH=x64
  set TEST_ARCHITECTURE=x64
  set TEST_CONFIG=Release
  set IS_SCENARIO_TEST=
  set USAGE_DISPLAYED=
  set SHOULD_UPLOAD_TO_BENCHVIEW=
  set BENCHVIEW_PATH=
  set COLLECTION_FLAGS=stopwatch
  set ETW_COLLECTION=Off
  set STABILITY_PREFIX=
  set BENCHVIEW_GROUP=CoreCLR
  set HAS_WARMUP_RUN=--drop-first-value
  set BETTER=desc
  set OPT_LEVEL=full_opt
  set VALID_OPTLEVELS=min_opt full_opt tiered

  call :parse_command_line_arguments %*
  if defined USAGE_DISPLAYED exit /b %ERRORLEVEL%

  call :is_valid_optlevel       || exit /b 1
  call :set_test_architecture   || exit /b 1
  call :set_collection_config   || exit /b 1
  call :verify_benchview_tools  || exit /b 1
  call :verify_core_overlay     || exit /b 1
  call :setup_sandbox           || exit /b 1
  call :set_perf_run_log        || exit /b 1
  call :build_perfharness       || exit /b 1

  call :run_cmd xcopy /sy "%CORECLR_REPO%\bin\tests\Windows_NT.%TEST_ARCH%.%TEST_CONFIG%\Tests\Core_Root"\* . >> %RUNLOG% || exit /b 1

  rem find and stage the tests
  set /A "LV_FAILURES=0"
  for /R %CORECLR_PERF% %%T in (*.%TEST_FILE_EXT%) do (
    call :run_benchmark %%T || (
      set /A "LV_FAILURES+=1"
    )
  )

  if not defined JIT_NAME (
    set JIT_NAME=ryujit
  )
  if not defined PGO_OPTIMIZED (
    set PGO_OPTIMIZED=pgo
  )

  rem optionally upload results to benchview
  if not [%BENCHVIEW_PATH%] == [] (
    call :upload_to_benchview || exit /b 1
  )

  rem Numbers are limited to 32-bits of precision (Int32.MAX == 2^32 - 1).
  if %LV_FAILURES% NEQ 0 (
    call :print_error %LV_FAILURES% benchmarks has failed.
    exit /b %LV_FAILURES%
  )

  exit /b %ERRORLEVEL%

:run_benchmark
rem ****************************************************************************
rem   Executes the xUnit Performance benchmarks
rem ****************************************************************************
setlocal
  set BENCHNAME=%~n1
  set BENCHDIR=%~p1

  rem copy benchmark and any input files
  call :run_cmd xcopy /sy %~1 . >> %RUNLOG%  || exit /b 1
  if exist "%BENCHDIR%*.txt" (
    call :run_cmd xcopy /sy %BENCHDIR%*.txt . >> %RUNLOG%  || exit /b 1
  )

  rem setup additional environment variables
  if DEFINED TEST_ENV (
    if EXIST "%TEST_ENV%" (
        call "%TEST_ENV%"
    )
  )

  call :setup_optimization_level

  rem CORE_ROOT environment variable is used by some benchmarks such as Roslyn / CscBench.
  set CORE_ROOT=%LV_SANDBOX_DIR%
  set LV_RUNID=Perf-%ETW_COLLECTION%

  if defined IS_SCENARIO_TEST (
    set "LV_BENCHMARK_OUTPUT_DIR=%LV_SANDBOX_OUTPUT_DIR%\Scenarios"
  ) else (
    set "LV_BENCHMARK_OUTPUT_DIR=%LV_SANDBOX_OUTPUT_DIR%\Microbenchmarks"
  )
  set "LV_BENCHMARK_OUTPUT_DIR=%LV_BENCHMARK_OUTPUT_DIR%\%ETW_COLLECTION%\%BENCHNAME%"

  set BENCHNAME_LOG_FILE_NAME=%LV_BENCHMARK_OUTPUT_DIR%\%LV_RUNID%-%BENCHNAME%.log

  if not defined LV_BENCHMARK_OUTPUT_DIR (
    call :print_error LV_BENCHMARK_OUTPUT_DIR was not defined.
    exit /b 1
  )
  if not exist "%LV_BENCHMARK_OUTPUT_DIR%" mkdir "%LV_BENCHMARK_OUTPUT_DIR%"
  if not exist "%LV_BENCHMARK_OUTPUT_DIR%" (
    call :print_error Failed to create the "%LV_BENCHMARK_OUTPUT_DIR%" directory.
    exit /b 1
  )

  echo/
  echo/  ----------
  echo/  Running %LV_RUNID% %BENCHNAME%
  echo/  ----------

  set "LV_COMMON_ARGS="%LV_SANDBOX_DIR%\%BENCHNAME%.%TEST_FILE_EXT%" --perf:outputdir "%LV_BENCHMARK_OUTPUT_DIR%" --perf:runid "%LV_RUNID%""
  if defined IS_SCENARIO_TEST (
    set "LV_COMMON_ARGS=%LV_COMMON_ARGS% --target-architecture "%TEST_ARCHITECTURE%""
  ) else (
    set "LV_COMMON_ARGS=PerfHarness.dll %LV_COMMON_ARGS%"
  )

  set "LV_CMD=%STABILITY_PREFIX% corerun.exe %LV_COMMON_ARGS% --perf:collect %COLLECTION_FLAGS%"
  call :print_to_console $ !LV_CMD!
  call :run_cmd !LV_CMD! 1>"%BENCHNAME_LOG_FILE_NAME%" 2>&1

  IF %ERRORLEVEL% NEQ 0 (
    call :print_error corerun.exe exited with %ERRORLEVEL% code.
    if exist "%BENCHNAME_LOG_FILE_NAME%" type "%BENCHNAME_LOG_FILE_NAME%"
    exit /b 1
  )

  rem optionally generate results for benchview
  if exist "%BENCHVIEW_PATH%" (
    call :generate_results_for_benchview || exit /b 1
  )

  exit /b 0

:parse_command_line_arguments
rem ****************************************************************************
rem   Parses the script's command line arguments.
rem ****************************************************************************
  IF /I [%~1] == [-testBinLoc] (
    set CORECLR_PERF=%CORECLR_REPO%\%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-stabilityPrefix] (
    set STABILITY_PREFIX=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-scenarioTest] (
    set IS_SCENARIO_TEST=1
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-uploadtobenchview] (
    set SHOULD_UPLOAD_TO_BENCHVIEW=1
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-nowarmup] (
    set HAS_WARMUP_RUN=
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-better] (
    set BETTER=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-runtype] (
    set BENCHVIEW_RUN_TYPE=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-collectionflags] (
    set COLLECTION_FLAGS=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-library] (
    set TEST_FILE_EXT=dll
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-generatebenchviewdata] (
    set BENCHVIEW_PATH=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-arch] (
    set TEST_ARCHITECTURE=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-testEnv] (
    set TEST_ENV=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-optLevel] (
    set OPT_LEVEL=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-jitName] (
    set JIT_NAME=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-nopgo] (
    set PGO_OPTIMIZED=nopgo
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-configuration] (
    set TEST_CONFIG=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-group] (
    set BENCHVIEW_GROUP=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )
  IF /I [%~1] == [-outputdir] (
    set LV_SANDBOX_OUTPUT_DIR=%~2
    shift
    shift
    goto :parse_command_line_arguments
  )

  if /I [%~1] == [-?] (
    call :USAGE
    exit /b 0
  )
  if /I [%~1] == [-help] (
    call :USAGE
    exit /b 0
  )

  if not defined CORECLR_PERF call :USAGE
  if not exist "%CORECLR_PERF%" (
    call :print_error Specified testBinLoc: "%CORECLR_PERF%" does not exist.
    call :USAGE
  )

  exit /b %ERRORLEVEL%

:set_test_architecture
rem ****************************************************************************
rem   Sets the test architecture.
rem ****************************************************************************
  set TEST_ARCH=%TEST_ARCHITECTURE%
  exit /b 0

:verify_benchview_tools
rem ****************************************************************************
rem   Verifies that the path to the benchview tools is correct.
rem ****************************************************************************
  if defined BENCHVIEW_PATH (
    if not exist "%BENCHVIEW_PATH%" (
      call :print_error BenchView path: "%BENCHVIEW_PATH%" was specified, but it does not exist.
      exit /b 1
    )
  )
  exit /b 0

:verify_core_overlay
rem ****************************************************************************
rem   Verify that the Core_Root folder exist.
rem ****************************************************************************
  set CORECLR_OVERLAY=%CORECLR_REPO%\bin\tests\Windows_NT.%TEST_ARCH%.%TEST_CONFIG%\Tests\Core_Root
  if NOT EXIST "%CORECLR_OVERLAY%" (
    call :print_error Can't find test overlay directory '%CORECLR_OVERLAY%'. Please build and run Release CoreCLR tests.
    exit /B 1
  )
  exit /b 0

:set_collection_config
rem ****************************************************************************
rem   Set's the config based on the providers used for collection
rem ****************************************************************************
  if /I [%COLLECTION_FLAGS%] == [stopwatch] (
    set ETW_COLLECTION=Off
  ) else (
    set ETW_COLLECTION=On
  )
  exit /b 0

:set_perf_run_log
rem ****************************************************************************
rem   Sets the script's output log file.
rem ****************************************************************************
  if NOT EXIST "%LV_SANDBOX_OUTPUT_DIR%" mkdir "%LV_SANDBOX_OUTPUT_DIR%"
  if NOT EXIST "%LV_SANDBOX_OUTPUT_DIR%" (
    call :print_error Cannot create the Logs folder "%LV_SANDBOX_OUTPUT_DIR%".
    exit /b 1
  )
  set "RUNLOG=%LV_SANDBOX_OUTPUT_DIR%\perfrun.log"
  exit /b 0

:setup_sandbox
rem ****************************************************************************
rem   Creates the sandbox folder used by the script to copy binaries locally,
rem   and execute benchmarks.
rem ****************************************************************************
  if not defined LV_SANDBOX_DIR (
    call :print_error LV_SANDBOX_DIR was not defined.
    exit /b 1
  )

  if exist "%LV_SANDBOX_DIR%" rmdir /s /q "%LV_SANDBOX_DIR%"
  if exist "%LV_SANDBOX_DIR%" (
    call :print_error Failed to remove the "%LV_SANDBOX_DIR%" folder
    exit /b 1
  )

  if not exist "%LV_SANDBOX_DIR%" mkdir "%LV_SANDBOX_DIR%"
  if not exist "%LV_SANDBOX_DIR%" (
    call :print_error Failed to create the "%LV_SANDBOX_DIR%" folder.
    exit /b 1
  )

  cd "%LV_SANDBOX_DIR%"
  exit /b %ERRORLEVEL%

:build_perfharness
rem ****************************************************************************
rem   Restores and publish the PerfHarness.
rem ****************************************************************************
  call :run_cmd "%CORECLR_REPO%\Tools\dotnetcli\dotnet.exe" --info || (
    call :print_error Failed to get information about the CLI tool.
    exit /b 1
  )
  call :run_cmd "%CORECLR_REPO%\Tools\dotnetcli\dotnet.exe" restore "%CORECLR_REPO%\tests\src\Common\PerfHarness\PerfHarness.csproj" || (
    call :print_error Failed to restore PerfHarness.csproj
    exit /b 1
  )
  call :run_cmd "%CORECLR_REPO%\Tools\dotnetcli\dotnet.exe" publish "%CORECLR_REPO%\tests\src\Common\PerfHarness\PerfHarness.csproj" -c Release -o "%LV_SANDBOX_DIR%" || (
    call :print_error Failed to publish PerfHarness.csproj
    exit /b 1
  )
  exit /b 0

:generate_results_for_benchview
rem ****************************************************************************
rem   Generates results for BenchView, by appending new data to the existing
rem   measurement.json file.
rem ****************************************************************************
  if not defined LV_RUNID (
    call :print_error LV_RUNID was not defined before calling generate_results_for_benchview.
    exit /b 1
  )
  set BENCHVIEW_MEASUREMENT_PARSER=xunit
  if defined IS_SCENARIO_TEST set BENCHVIEW_MEASUREMENT_PARSER=xunitscenario

  set LV_MEASUREMENT_ARGS=
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% %BENCHVIEW_MEASUREMENT_PARSER%
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% --better %BETTER%
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% %HAS_WARMUP_RUN%
  set LV_MEASUREMENT_ARGS=%LV_MEASUREMENT_ARGS% --append

  rem Currently xUnit Performance Api saves the scenario output
  rem   files on the current working directory.
  set "LV_PATTERN=%LV_BENCHMARK_OUTPUT_DIR%\%LV_RUNID%-*.xml"
  for %%f in (%LV_PATTERN%) do (
    if exist "%%~f" (
      call :run_cmd py.exe "%BENCHVIEW_PATH%\measurement.py" %LV_MEASUREMENT_ARGS% "%%~f" || (
        call :print_error
        type "%%~f"
        exit /b 1
      )
    )
  )

endlocal& exit /b %ERRORLEVEL%

:upload_to_benchview
rem ****************************************************************************
rem   Generates BenchView's submission data and upload it
rem ****************************************************************************
setlocal
  if not exist measurement.json (
    call :print_error measurement.json does not exist. There is no data to be uploaded.
    exit /b 1
  )

  set LV_SUBMISSION_ARGS=
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --build "%CORECLR_REPO%\build.json"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --machine-data "%CORECLR_REPO%\machinedata.json"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --metadata "%CORECLR_REPO%\submission-metadata.json"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --group "%BENCHVIEW_GROUP%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --type "%BENCHVIEW_RUN_TYPE%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config-name "%TEST_CONFIG%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config Configuration "%TEST_CONFIG%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config OS "Windows_NT"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config Profile "%ETW_COLLECTION%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config OptLevel "%OPT_LEVEL%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config JitName  "%JIT_NAME%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --config PGO  "%PGO_OPTIMIZED%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --architecture "%TEST_ARCHITECTURE%"
  set LV_SUBMISSION_ARGS=%LV_SUBMISSION_ARGS% --machinepool "PerfSnake"

  call :run_cmd py.exe "%BENCHVIEW_PATH%\submission.py" measurement.json %LV_SUBMISSION_ARGS%

  IF %ERRORLEVEL% NEQ 0 (
    call :print_error Creating BenchView submission data failed.
    exit /b 1
  )

  if defined SHOULD_UPLOAD_TO_BENCHVIEW (
    call :run_cmd py.exe "%BENCHVIEW_PATH%\upload.py" submission.json --container coreclr
    IF !ERRORLEVEL! NEQ 0 (
      call :print_error Uploading to BenchView failed.
      exit /b 1
    )
  )
  exit /b %ERRORLEVEL%

:USAGE
rem ****************************************************************************
rem   Script's usage.
rem ****************************************************************************
  set USAGE_DISPLAYED=1
  echo run-xunit-perf.cmd -testBinLoc ^<path_to_tests^> [-library] [-arch] ^<x86^|x64^> [-configuration] ^<Release^|Debug^> [-generateBenchviewData] ^<path_to_benchview_tools^> [-warmup] [-better] ^<asc ^| desc^> [-group] ^<group^> [-runtype] ^<rolling^|private^> [-scenarioTest] [-collectionFlags] ^<default^+CacheMisses^+InstructionRetired^+BranchMispredictions^+gcapi^> [-outputdir] ^<outputdir^> [-optLevel] ^<%VALID_OPTLEVELS: =^|%^>
  echo/
  echo For the path to the tests you can pass a parent directory and the script will grovel for
  echo all tests in subdirectories and run them.
  echo The library flag denotes whether the tests are build as libraries (.dll) or an executable (.exe)
  echo Architecture defaults to x64 and configuration defaults to release.
  echo -generateBenchviewData is used to specify a path to the Benchview tooling and when this flag is
  echo set we will generate the results for upload to benchview.
  echo -uploadToBenchview If this flag is set the generated benchview test data will be uploaded.
  echo -nowarmup specifies not to discard the results of the first run
  echo -better whether it is better to have ascending or descending numbers for the benchmark
  echo -group specifies the Benchview group to which this data should be uploaded (default CoreCLR)
  echo Runtype sets the runtype that we upload to Benchview, rolling for regular runs, and private for
  echo PRs.
  echo -scenarioTest should be included if you are running a scenario benchmark.
  echo -outputdir Specifies the directory where the generated performance output will be saved.
  echo -collectionFlags This is used to specify what collectoin flags get passed to the performance
  echo -optLevel Specifies the optimization level to be used by the jit.
  echo harness that is doing the test running.  If this is not specified we only use stopwatch.
  echo Other flags are "default", which is the whatever the test being run specified, "CacheMisses",
  echo "BranchMispredictions", and "InstructionsRetired".
  exit /b %ERRORLEVEL%

:print_error
rem ****************************************************************************
rem   Function wrapper that unifies how errors are output by the script.
rem   Functions output to the standard error.
rem ****************************************************************************
  call :print_to_console [ERROR] %*   1>&2
  exit /b %ERRORLEVEL%

:print_to_console
rem ****************************************************************************
rem   Sends text to the console screen. This can be useful to provide
rem   information on where the script is executing.
rem ****************************************************************************
  echo/
  echo/%USERNAME%@%COMPUTERNAME% "%CD%"
  echo/[%DATE%][%TIME:~0,-3%] %*
  exit /b %ERRORLEVEL%

:is_valid_optlevel
rem ****************************************************************************
rem   Validates the optlevel flag set by the user.
rem ****************************************************************************
setlocal
  if not defined OPT_LEVEL (
    call :print_error OPT_LEVEL is undefined.
    exit /b 1
  )

  set "LV_IS_VALID_OPTLEVEL="
  for %%i in (%VALID_OPTLEVELS%) do (
    if /i "%%~i" == "%OPT_LEVEL%" (
      set "LV_IS_VALID_OPTLEVEL=1"
    )
  )

  if not defined LV_IS_VALID_OPTLEVEL (
    call :print_error Unknown OPT_LEVEL=%OPT_LEVEL%
    exit /b 1
  )
endlocal& exit /b 0

:setup_optimization_level
rem ****************************************************************************
rem   Setup the appropriate environment variables needed for the selected
rem   optlevel.
rem ****************************************************************************
  set "COMPlus_JITMinOpts="
  set "COMPLUS_EXPERIMENTAL_TieredCompilation="

  if /I "%OPT_LEVEL%" == "min_opt" (
    set COMPlus_JITMinOpts=1
    exit /b 0
  )
  if /I "%OPT_LEVEL%" == "tiered" (
    set COMPLUS_EXPERIMENTAL_TieredCompilation=1
    exit /b 0
  )
exit /b 0

:run_cmd
rem ****************************************************************************
rem   Function wrapper used to send the command line being executed to the
rem   console screen, before the command is executed.
rem ****************************************************************************
  if "%~1" == "" (
    call :print_error No command was specified.
    exit /b 1
  )

  call :print_to_console $ %*
  call %*
  exit /b %ERRORLEVEL%
