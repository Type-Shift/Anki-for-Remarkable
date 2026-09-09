#ifndef WIFIMANAGER_H
#define WIFIMANAGER_H

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>

#include <functional>

// ---------------------------------------------------------------------------
// WifiManager
//
// Wraps nmcli so WiFi can be managed from inside the app. Necessary because
// running a Qt epaper app requires stopping xochitl, which takes reMarkable's
// own settings UI down with it -- leaving no other way to join a network.
//
// The 2026-08-27 firmware moved to NetworkManager and starts wpa_supplicant
// with -u, which serves D-Bus and creates no control socket at all, so the
// wpa_cli this used to drive fails outright. NetworkManager keeps saved
// networks under /etc, so joins survive a reboot -- but not a firmware
// update, which replaces /etc wholesale.
// ---------------------------------------------------------------------------

class QTimer;

class WifiManager : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString status      READ status      NOTIFY statusChanged)
    Q_PROPERTY(QString currentSsid READ currentSsid NOTIFY statusChanged)
    Q_PROPERTY(QString ipAddress   READ ipAddress   NOTIFY statusChanged)
    Q_PROPERTY(bool connected      READ connected   NOTIFY statusChanged)
    Q_PROPERTY(bool scanning       READ scanning    NOTIFY scanningChanged)
    Q_PROPERTY(QVariantList networks READ networks  NOTIFY networksChanged)
    Q_PROPERTY(QString wifiError   READ wifiError   NOTIFY wifiErrorChanged)

public:
    explicit WifiManager(QObject *parent = nullptr);

    QString status() const { return m_status; }
    QString currentSsid() const { return m_currentSsid; }
    QString ipAddress() const { return m_ipAddress; }
    bool connected() const { return m_status == QLatin1String("COMPLETED"); }
    bool scanning() const { return m_scanning; }
    QVariantList networks() const { return m_networks; }
    QString wifiError() const { return m_wifiError; }

    Q_INVOKABLE void refreshStatus();
    Q_INVOKABLE void scan();
    Q_INVOKABLE void connectToNetwork(const QString &ssid, const QString &password);
    Q_INVOKABLE void connectToSaved(const QString &ssid);
    Q_INVOKABLE void forgetNetwork(const QString &ssid);
    Q_INVOKABLE void disconnectWifi();
    Q_INVOKABLE void reconnectWifi();

signals:
    void statusChanged();
    void scanningChanged();
    void networksChanged();
    void wifiErrorChanged();

private slots:
    // Status, network list, and a rescan every few ticks.
    void poll();

private:
    // Called with (ok, stdout) once nmcli exits. ok is false on a non-zero
    // exit, a failure to start, or the timeout; nmcli's own message goes to
    // wifiError either way.
    using Handler = std::function<void(bool, const QString &)>;

    // Runs `nmcli <args>` without blocking. Everything here used to run on
    // the GUI thread via waitForFinished, which stalled the display on every
    // poll and froze the app outright for the length of a join.
    void run(const QStringList &args, int timeoutMs = 8000, Handler done = nullptr);

    void refreshNetworks();

    void setStatusFields(const QString &state, const QString &ssid, const QString &ip);
    void setScanning(bool s);
    void setWifiError(const QString &e);
    void rebuildNetworks(const QString &scanOutput, const QStringList &saved);

    QString      m_status = QStringLiteral("UNKNOWN");
    QString      m_currentSsid;
    QString      m_ipAddress;
    QVariantList m_networks;
    QString      m_wifiError;
    bool         m_scanning = false;

    QTimer *m_pollTimer = nullptr;

    // Polls since the last forced rescan, so the list keeps filling in
    // without the user having to ask for a scan.
    int m_pollsSinceScan = 0;
};

#endif // WIFIMANAGER_H
