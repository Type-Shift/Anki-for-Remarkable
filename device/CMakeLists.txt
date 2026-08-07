cmake_minimum_required(VERSION 3.16)
project(anki VERSION 0.1 LANGUAGES CXX)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Qt6 REQUIRED COMPONENTS Quick)
qt_standard_project_setup(REQUIRES 6.5)

# ankiclient.cpp (the online AnkiWeb client) is kept in the tree for
# reference but is no longer built: the app is offline-only now.
qt_add_executable(anki
    main.cpp
    offlineclient.cpp  offlineclient.h
    wifimanager.cpp    wifimanager.h
    deviceactions.cpp  deviceactions.h)

qt_add_qml_module(anki
    URI anki_app
    VERSION 1.0
    QML_FILES Main.qml)

target_link_libraries(anki PRIVATE Qt6::Quick)
