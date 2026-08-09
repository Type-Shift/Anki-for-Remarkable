cmake_minimum_required(VERSION 3.16)
project(anki VERSION 0.1 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick)
qt_standard_project_setup(REQUIRES 6.5)

# Anki's own Rust backend, cross-compiled separately by CI. Passed in rather
# than discovered, so the build fails loudly if the library is missing instead
# of silently producing an app without a scheduler.
set(ANKICORE_LIB "" CACHE FILEPATH "Path to libankicore.a")

# ankiclient.cpp (the original online AnkiWeb client) is kept in the tree for
# reference but is no longer built: the app is offline-only now.
qt_add_executable(anki
    main.cpp
    offlineclient.cpp  offlineclient.h
    wifimanager.cpp    wifimanager.h
    deviceactions.cpp  deviceactions.h
    syncmanager.cpp    syncmanager.h
    ankicore.h)

qt_add_qml_module(anki
    URI anki_app
    VERSION 1.0
    QML_FILES Main.qml)

target_link_libraries(anki PRIVATE Qt6::Quick)

# Required, not optional: the app now schedules exclusively through rslib.
# There is no batch-file fallback left to degrade to, so a missing library
# must fail the build rather than produce an app with no scheduler.
if(NOT ANKICORE_LIB)
    message(FATAL_ERROR
        "ANKICORE_LIB not set. Build device/ankicore first and pass "
        "-DANKICORE_LIB=/path/to/libankicore.a")
endif()
if(NOT EXISTS "${ANKICORE_LIB}")
    message(FATAL_ERROR "ANKICORE_LIB set to '${ANKICORE_LIB}' but no such file")
endif()
message(STATUS "Linking Anki backend: ${ANKICORE_LIB}")

# A Rust staticlib brings its own runtime, which needs the usual system
# libraries. Without these the link fails on undefined pthread/dlopen symbols
# rather than anything that points at Rust.
target_link_libraries(anki PRIVATE
    "${ANKICORE_LIB}"
    pthread
    dl
    m
    rt)
target_compile_definitions(anki PRIVATE HAVE_ANKICORE=1)
