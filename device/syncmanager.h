#ifndef SYNCMANAGER_H
#define SYNCMANAGER_H

#include <QObject>
#include <QString>

// ---------------------------------------------------------------------------
// SyncManager
//
// AnkiWeb sync, through rslib's own sync client. The tablet is a real Anki
// client here: it merges properly rather than copying a file over the top of
// whatever the other side had.
//
// The sync key is stored on the device so the password is only ever typed
// once. rslib returns that key from a login exchange; the password itself is
// never written down.
//
// Sync runs on a worker thread. rslib's call blocks until it finishes, and on
// this single-core device that would freeze the UI mid-sync with no way to
// show progress.
// ---------------------------------------------------------------------------

class SyncManager : public QObject
{
    Q_OBJECT

    Q_PROPERTY(bool loggedIn      READ loggedIn      NOTIFY loggedInChanged)
    Q_PROPERTY(bool busy          READ busy          NOTIFY busyChanged)
    Q_PROPERTY(QString status     READ status        NOTIFY statusChanged)
    Q_PROPERTY(QString lastError  READ lastError     NOTIFY statusChanged)
    Q_PROPERTY(QString endpoint   READ endpoint      WRITE setEndpoint NOTIFY endpointChanged)

public:
    explicit SyncManager(QObject *parent = nullptr);

    bool loggedIn() const { return !m_hkey.isEmpty(); }
    bool busy() const { return m_busy; }
    QString status() const { return m_status; }
    QString lastError() const { return m_lastError; }
    QString endpoint() const { return m_endpoint; }
    void setEndpoint(const QString &e);

    /// Exchange an AnkiWeb email and password for a sync key, and remember it.
    Q_INVOKABLE void login(const QString &email, const QString &password);
    /// Sync now, using the stored key.
    Q_INVOKABLE void sync();
    /// Forget the stored key.
    Q_INVOKABLE void logout();

signals:
    void loggedInChanged();
    void busyChanged();
    void statusChanged();
    void endpointChanged();
    /// Emitted after a successful sync so the deck list can be reloaded:
    /// the collection has changed underneath it.
    void syncFinished(bool ok);

private:
    void setBusy(bool b);
    void setStatus(const QString &s, const QString &err = QString());
    void loadKey();
    void saveKey(const QString &hkey);

    QString m_hkey;
    QString m_endpoint;      // empty = AnkiWeb
    QString m_status;
    QString m_lastError;
    bool    m_busy = false;

    QString m_keyPath;
};

#endif // SYNCMANAGER_H
