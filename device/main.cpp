#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>

#include "offlineclient.h"

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);

    // Exposed as "anki" so Main.qml binds unchanged; OfflineAnkiClient
    // presents the same properties and invokables the online client did.
    OfflineAnkiClient client;

    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("anki"), &client);

    QObject::connect(
        &engine,
        &QQmlApplicationEngine::objectCreationFailed,
        &app,
        []() { QCoreApplication::exit(-1); },
        Qt::QueuedConnection);
    engine.loadFromModule("anki_app", "Main");

    return app.exec();
}
