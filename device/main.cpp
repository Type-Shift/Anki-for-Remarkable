#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

#include "offlineclient.h"
#include "wifimanager.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    // Exposed as "anki" so Main.qml binds unchanged; OfflineAnkiClient
    // presents the same properties and invokables the online client did.
    OfflineAnkiClient client;

    // Wi-Fi has to be reachable from inside the app: launching a Qt epaper
    // app means stopping xochitl, which takes reMarkable's settings UI with it.
    WifiManager wifi;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("anki"), &client);
    engine.rootContext()->setContextProperty(QStringLiteral("wifi"), &wifi);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("anki_app", "Main");

    return app.exec();
}
