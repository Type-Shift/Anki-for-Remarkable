#include "syncmanager.h"

#include <thread>

#include <QDebug>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>

#include "ankicore.h"

namespace {
// Alongside the collection, not under QDir::homePath(): systemd services
// inherit no HOME, so that resolves to "/" under the launcher.
const char *KEY_PATH      = "/home/root/.anki-sync-key";
const char *ENDPOINT_PATH = "/home/root/.anki-sync-endpoint";

/// Parse one of ankicore's JSON replies. Returns the object, and sets `error`
/// when the call reported failure.
QJsonObject parseReply(char *raw, QString *error)
{
    if (!raw) {
        *error = QStringLiteral("the Anki backend returned nothing");
        return {};
    }
    const QByteArray payload(raw);
    ankicore_free_string(raw);

    const QJsonDocument doc = QJsonDocument::fromJson(payload);
    if (!doc.isObject()) {
        *error = QStringLiteral("could not read the backend's reply");
        return {};
    }
    const QJsonObject obj = doc.object();
    if (!obj.value(QStringLiteral("ok")).toBool(false)) {
        *error = obj.value(QStringLiteral("error"))
                     .toString(QStringLiteral("unknown error"));
        return {};
    }
    return obj;
}
}

SyncManager::SyncManager(QObject *parent)
    : QObject(parent)
    , m_keyPath(QString::fromLatin1(KEY_PATH))
{
    loadKey();
}

void SyncManager::loadKey()
{
    QFile f(m_keyPath);
    if (f.open(QIODevice::ReadOnly))
        m_hkey = QString::fromUtf8(f.readAll()).trimmed();

    QFile e(QString::fromLatin1(ENDPOINT_PATH));
    if (e.open(QIODevice::ReadOnly))
        m_endpoint = QString::fromUtf8(e.readAll()).trimmed();
}

void SyncManager::saveKey(const QString &hkey)
{
    QFile f(m_keyPath);
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        qWarning() << "sync: could not store the sync key at" << m_keyPath;
        return;
    }
    f.write(hkey.toUtf8());
    f.close();
    // The key grants access to the account; keep it off other users' eyes
    // even though this device has only one.
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
}

void SyncManager::setEndpoint(const QString &e)
{
    const QString trimmed = e.trimmed();
    if (m_endpoint == trimmed) return;
    m_endpoint = trimmed;

    QFile f(QString::fromLatin1(ENDPOINT_PATH));
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.write(m_endpoint.toUtf8());
        f.close();
    }
    emit endpointChanged();
}

void SyncManager::setBusy(bool b)
{
    if (m_busy == b) return;
    m_busy = b;
    emit busyChanged();
}

void SyncManager::setStatus(const QString &s, const QString &err)
{
    m_status = s;
    m_lastError = err;
    emit statusChanged();
    if (!err.isEmpty()) qWarning().noquote() << "sync:" << err;
}

void SyncManager::login(const QString &email, const QString &password)
{
    if (m_busy) return;
    if (email.trimmed().isEmpty() || password.isEmpty()) {
        setStatus(QStringLiteral("Enter your AnkiWeb email and password"),
                  QStringLiteral("missing credentials"));
        return;
    }

    setBusy(true);
    setStatus(QStringLiteral("Signing in..."));

    const QByteArray ep = m_endpoint.toUtf8();
    const QByteArray em = email.trimmed().toUtf8();
    const QByteArray pw = password.toUtf8();

    // Detached thread with results posted back to the UI thread: rslib's
    // login blocks on the network, which would otherwise stall the display.
    std::thread([this, ep, em, pw]() {
        QString error;
        const QJsonObject obj =
            parseReply(ankicore_sync_login(ep.constData(), em.constData(), pw.constData()),
                       &error);
        const QString hkey = obj.value(QStringLiteral("hkey")).toString();

        QMetaObject::invokeMethod(this, [this, hkey, error]() {
            setBusy(false);
            if (!error.isEmpty()) {
                setStatus(QStringLiteral("Sign-in failed"), error);
                return;
            }
            m_hkey = hkey;
            saveKey(hkey);
            emit loggedInChanged();
            setStatus(QStringLiteral("Signed in"));
            sync();     // the point of signing in
        }, Qt::QueuedConnection);
    }).detach();
}

void SyncManager::sync()
{
    if (m_busy) return;
    if (m_hkey.isEmpty()) {
        setStatus(QStringLiteral("Sign in to AnkiWeb first"),
                  QStringLiteral("no sync key stored"));
        return;
    }

    m_fullSyncNeeded = false;
    setBusy(true);
    setStatus(QStringLiteral("Syncing..."));

    const QByteArray ep = m_endpoint.toUtf8();
    const QByteArray key = m_hkey.toUtf8();

    std::thread([this, ep, key]() {
        QString error;
        const QJsonObject obj =
            parseReply(ankicore_sync(ep.constData(), key.constData()), &error);
        const QString required = obj.value(QStringLiteral("required")).toString();
        const bool reallySynced = obj.value(QStringLiteral("synced")).toBool(false);
        const bool fullSyncRequired =
            obj.value(QStringLiteral("full_sync_required")).toBool(false);

        QMetaObject::invokeMethod(this, [this, required, reallySynced,
                                         fullSyncRequired, error]() {
            setBusy(false);
            if (!error.isEmpty()) {
                // An expired or revoked key reads as an auth failure; make the
                // user sign in again rather than retrying forever.
                if (error.contains(QStringLiteral("AuthFailed"), Qt::CaseInsensitive) ||
                    error.contains(QStringLiteral("auth"), Qt::CaseInsensitive)) {
                    m_hkey.clear();
                    emit loggedInChanged();
                    setStatus(QStringLiteral("Sign in again"), error);
                } else {
                    setStatus(QStringLiteral("Sync failed"), error);
                }
                emit syncFinished(false);
                return;
            }
            // rslib returning Ok does not mean anything moved. When the
            // server cannot merge, it asks for a full sync and nothing has
            // been transferred -- saying "Synced" there was simply untrue.
            if (fullSyncRequired) {
                m_fullSyncNeeded = true;
                setStatus(QStringLiteral("Full sync needed"),
                          QStringLiteral("this device and AnkiWeb have diverged; "
                                         "choose which one wins"));
                emit syncFinished(false);
                return;
            }
            if (!reallySynced) {
                setStatus(QStringLiteral("Not synced"),
                          QStringLiteral("server replied: ") + required);
                emit syncFinished(false);
                return;
            }
            setStatus(QStringLiteral("Synced"));
            emit syncFinished(true);
        }, Qt::QueuedConnection);
    }).detach();
}

void SyncManager::fullSync(const QString &direction)
{
    if (m_busy) return;
    if (m_hkey.isEmpty()) {
        setStatus(QStringLiteral("Sign in to AnkiWeb first"),
                  QStringLiteral("no sync key stored"));
        return;
    }
    if (direction != QLatin1String("upload") && direction != QLatin1String("download")) {
        setStatus(QStringLiteral("Sync failed"),
                  QStringLiteral("unknown direction: ") + direction);
        return;
    }

    setBusy(true);
    setStatus(direction == QLatin1String("upload")
                  ? QStringLiteral("Uploading everything...")
                  : QStringLiteral("Downloading everything..."));

    const QByteArray ep  = m_endpoint.toUtf8();
    const QByteArray key = m_hkey.toUtf8();
    const QByteArray dir = direction.toUtf8();

    std::thread([this, ep, key, dir]() {
        QString error;
        parseReply(ankicore_full_sync(ep.constData(), key.constData(), dir.constData()),
                   &error);

        QMetaObject::invokeMethod(this, [this, error]() {
            setBusy(false);
            if (!error.isEmpty()) {
                setStatus(QStringLiteral("Full sync failed"), error);
                emit syncFinished(false);
                return;
            }
            m_fullSyncNeeded = false;
            setStatus(QStringLiteral("Synced"));
            emit syncFinished(true);
        }, Qt::QueuedConnection);
    }).detach();
}

void SyncManager::logout()
{
    m_hkey.clear();
    QFile::remove(m_keyPath);
    emit loggedInChanged();
    setStatus(QStringLiteral("Signed out"));
}
