@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\VsDevCmd.bat" -arch=x64 -host_arch=x64 >nul
cd /d "D:\Claude Dev\HellraiserAimFixProject"
cmake -S . -B build -G "Visual Studio 18 2026" -A x64 -DCMAKE_BUILD_TYPE=Release -DFETCHCONTENT_FULLY_DISCONNECTED=ON -DFETCHCONTENT_SOURCE_DIR_BDDISASM="D:/Claude Dev/CronosAimFixProject/build/_deps/bddisasm-src" -DFETCHCONTENT_SOURCE_DIR_SPDLOG="D:/Claude Dev/CronosAimFixProject/build/_deps/spdlog-src" -DFETCHCONTENT_SOURCE_DIR_KANANLIB="D:/Claude Dev/CronosAimFixProject/build/_deps/kananlib-src" || exit /b 1
cmake --build build --config Release --target HellraiserAimFix -- -m
