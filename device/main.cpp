#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

#include "deviceactions.h"
#include "offlineclient.h"
#include "wifimanager.h"

#ifdef HAVE_ANKICORE
#include <QDebug>
#include "ankicore.h"
#endif

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

#ifdef HAVE_ANKICORE
    // Prove the Rust backend is linked and callable before anything depends
    // on it. A link that succeeds but faults at the first call would
    // otherwise show up as a mystery crash mid-review.
    if (char *v = ankicore_version()) {
        qInfo().noquote() << "ankicore:" << v;
        ankicore_free_string(v);
    } else {
        qWarning() << "ankicore: version call returned null";
    }
#endif

    // Exposed as "anki" so Main.qml binds unchanged; OfflineAnkiClient
    // presents the same properties and invokables the online client did.
    OfflineAnkiClient client;

    // Wi-Fi has to be reachable from inside the app: launching a Qt epaper
    // app means stopping xochitl, which takes reMarkable's settings UI with it.
    WifiManager wifi;

    // Lets the user hand the framebuffer back to xochitl without a PC.
    DeviceActions device;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("anki"), &client);
    engine.rootContext()->setContextProperty(QStringLiteral("wifi"), &wifi);
    engine.rootContext()->setContextProperty(QStringLiteral("device"), &device);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("anki_app", "Main");

    return app.exec();
}
