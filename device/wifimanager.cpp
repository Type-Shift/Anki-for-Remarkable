#include "wifimanager.h"

#include <QDebug>
#include <QProcess>
#include <QTimer>
#include <QVariantMap>

namespace {
const char *IFACE = "wlan0";
constexpr int NM_TIMEOUT_MS   = 6000;
constexpr int JOIN_TIMEOUT_MS = 15000;  // joining waits on association + DHCP
constexpr int SCAN_WAIT_MS    = 3500;
constexpr int POLL_MS         = 4000;   // refresh status while the panel is open

// nmcli -t escapes a literal colon inside a field as a backslash-colon, so a
// plain split on ':' tears an SSID containing one in half.
QStringList splitTerse(const QString &line)
{
    QStringList out;
    QString cur;
    for (int i = 0; i < line.size(); ++i) {
        const QChar c = line.at(i);
        if (c == QLatin1Char('\\') && i + 1 < line.size()) {
            cur.append(line.at(++i));
        } else if (c == QLatin1Char(':')) {
            out << cur;
            cur.clear();
        } else {
            cur.append(c);
        }
    }
    out << cur;
    return out;
}
}

WifiManager::WifiManager(QObject *parent)
    : QObject(parent)
{
    m_scanTimer = new QTimer(this);
    m_scanTimer->setSingleShot(true);
    connect(m_scanTimer, &QTimer::timeout, this, &WifiManager::collectScanResults);

    // Association and DHCP take a few seconds; poll so the UI reflects
    // reality without the user having to prod it.
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(POLL_MS);
    connect(m_pollTimer, &QTimer::timeout, this, &WifiManager::refreshStatus);
    m_pollTimer->start();

    refreshStatus();
}

// --- command plumbing -------------------------------------------------------

QString WifiManager::nm(const QStringList &args, bool *ok, int timeoutMs)
{
    QProcess p;
    // Arguments go straight to execve, so an SSID or password containing
    // spaces or quotes needs no escaping and cannot reach a shell.
    p.start(QStringLiteral("nmcli"), args);
    if (!p.waitForStarted(NM_TIMEOUT_MS)) {
        if (ok) *ok = false;
        setWifiError(QStringLiteral("nmcli not available on this device"));
        return QString();
    }
    if (!p.waitForFinished(timeoutMs)) {
        p.kill();
        if (ok) *ok = false;
        setWifiError(QStringLiteral("nmcli timed out"));
        return QString();
    }

    const QString out = QString::fromUtf8(p.readAllStandardOutput());
    const bool good = (p.exitStatus() == QProcess::NormalExit && p.exitCode() == 0);
    if (ok) *ok = good;
    if (!good) {
        const QString err = QString::fromUtf8(p.readAllStandardError()).trimmed();
        if (!err.isEmpty()) setWifiError(err.section(QLatin1Char('\n'), -1));
    }
    return out;
}

void WifiManager::setStatusFields(const QString &state, const QString &ssid, const QString &ip)
{
    if (m_status == state && m_currentSsid == ssid && m_ipAddress == ip) return;
    m_status      = state;
    m_currentSsid = ssid;
    m_ipAddress   = ip;
    emit statusChanged();
}

void WifiManager::setScanning(bool s)
{
    if (m_scanning == s) return;
    m_scanning = s;
    emit scanningChanged();
}

void WifiManager::setWifiError(const QString &e)
{
    if (m_wifiError == e) return;
    m_wifiError = e;
    emit wifiErrorChanged();
}

// --- status -----------------------------------------------------------------

void WifiManager::refreshStatus()
{
    bool ok = false;
    const QString radio = nm({QStringLiteral("-t"), QStringLiteral("radio"),
                              QStringLiteral("wifi")}, &ok).trimmed();
    if (!ok) {
        setStatusFields(QStringLiteral("UNAVAILABLE"), QString(), QString());
        return;
    }
    if (radio == QLatin1String("disabled")) {
        setStatusFields(QStringLiteral("DISCONNECTED"), QString(), QString());
        return;
    }

    const QString out = nm({QStringLiteral("-t"),
                            QStringLiteral("-f"),
                            QStringLiteral("GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS"),
                            QStringLiteral("device"), QStringLiteral("show"),
                            QLatin1String(IFACE)}, &ok);
    if (!ok) {
        setStatusFields(QStringLiteral("UNAVAILABLE"), QString(), QString());
        return;
    }

    int deviceState = 0;
    QString ssid, ip;
    const QStringList lines = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        const QStringList f = splitTerse(line);
        if (f.size() < 2) continue;
        const QString key = f.first();
        const QString val = QStringList(f.mid(1)).join(QLatin1Char(':')).trimmed();

        // "100 (connected)" -- the number is the stable part, the word is
        // translated and can change between firmware versions.
        if (key == QLatin1String("GENERAL.STATE"))
            deviceState = val.section(QLatin1Char(' '), 0, 0).toInt();
        else if (key == QLatin1String("GENERAL.CONNECTION"))
            ssid = (val == QLatin1String("--")) ? QString() : val;
        else if (key.startsWith(QLatin1String("IP4.ADDRESS")))
            ip = val.section(QLatin1Char('/'), 0, 0);
    }

    // NetworkManager device states: 100 activated, anything from preparing
    // (40) up to secondaries (90) is on its way, below that is down.
    QString state;
    if (deviceState >= 100)     state = QStringLiteral("COMPLETED");
    else if (deviceState >= 40) state = QStringLiteral("CONNECTING");
    else                        state = QStringLiteral("DISCONNECTED");

    setStatusFields(state, ssid, ip);

    // No reconnect loop here on purpose. The old firmware left that to us;
    // NetworkManager does it itself, and polling it into a fight produced a
    // reconnect every eight seconds against a link that was already up.
}

// --- scanning ---------------------------------------------------------------

void WifiManager::scan()
{
    setWifiError(QString());
    setScanning(true);
    nm({QStringLiteral("device"), QStringLiteral("wifi"), QStringLiteral("rescan")});
    m_scanTimer->start(SCAN_WAIT_MS);
}

void WifiManager::collectScanResults()
{
    const QString out = nm({QStringLiteral("-t"), QStringLiteral("-f"),
                            QStringLiteral("SSID,SIGNAL,SECURITY"),
                            QStringLiteral("device"), QStringLiteral("wifi"),
                            QStringLiteral("list")});
    rebuildNetworks(out);
    setScanning(false);
    refreshStatus();
}

void WifiManager::rebuildNetworks(const QString &scanOutput)
{
    // Saved connections, so the UI can offer one-tap rejoin without a
    // password. NetworkManager names a Wi-Fi connection after its SSID.
    QStringList saved;
    const QString savedOut = nm({QStringLiteral("-t"), QStringLiteral("-f"),
                                 QStringLiteral("NAME,TYPE"),
                                 QStringLiteral("connection"), QStringLiteral("show")});
    const QStringList savedLines = savedOut.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : savedLines) {
        const QStringList f = splitTerse(line);
        if (f.size() >= 2 && f.at(1).contains(QLatin1String("wireless")))
            saved << f.at(0);
    }

    QMap<QString, QVariantMap> best;
    const QStringList lines = scanOutput.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        const QStringList f = splitTerse(line);
        if (f.size() < 3) continue;

        const QString ssid = f.at(0).trimmed();
        if (ssid.isEmpty()) continue;                 // hidden network

        // nmcli reports 0-100 quality, not dBm as wpa_cli did.
        const int signal = f.at(1).trimmed().toInt();
        const bool secured = !f.at(2).trimmed().isEmpty();

        // Same SSID often appears per-band and per-AP; keep the strongest.
        if (best.contains(ssid) && best[ssid].value(QStringLiteral("signal")).toInt() >= signal)
            continue;

        QVariantMap n;
        n.insert(QStringLiteral("ssid"),    ssid);
        n.insert(QStringLiteral("signal"),  signal);
        n.insert(QStringLiteral("secured"), secured);
        n.insert(QStringLiteral("saved"),   saved.contains(ssid));
        n.insert(QStringLiteral("current"), ssid == m_currentSsid);
        const int bars = (signal >= 80) ? 4 : (signal >= 60) ? 3
                       : (signal >= 40) ? 2 : (signal >= 20) ? 1 : 0;
        n.insert(QStringLiteral("bars"), bars);
        best.insert(ssid, n);
    }

    QList<QVariantMap> sorted = best.values();
    std::sort(sorted.begin(), sorted.end(), [](const QVariantMap &a, const QVariantMap &b) {
        // Current network first, then saved, then by signal strength.
        if (a.value(QStringLiteral("current")).toBool() != b.value(QStringLiteral("current")).toBool())
            return a.value(QStringLiteral("current")).toBool();
        if (a.value(QStringLiteral("saved")).toBool() != b.value(QStringLiteral("saved")).toBool())
            return a.value(QStringLiteral("saved")).toBool();
        return a.value(QStringLiteral("signal")).toInt() > b.value(QStringLiteral("signal")).toInt();
    });

    m_networks.clear();
    for (const QVariantMap &n : sorted)
        m_networks.append(n);
    emit networksChanged();
}

// --- joining ----------------------------------------------------------------

void WifiManager::connectToSaved(const QString &ssid)
{
    setWifiError(QString());
    nm({QStringLiteral("connection"), QStringLiteral("up"),
        QStringLiteral("id"), ssid}, nullptr, JOIN_TIMEOUT_MS);
    setStatusFields(QStringLiteral("CONNECTING"), ssid, QString());
    QTimer::singleShot(2000, this, &WifiManager::refreshStatus);
}

void WifiManager::connectToNetwork(const QString &ssid, const QString &password)
{
    setWifiError(QString());

    if (ssid.trimmed().isEmpty()) {
        setWifiError(QStringLiteral("Choose a network first"));
        return;
    }

    // "device wifi connect" creates the saved connection as a side effect, so
    // it survives a reboot and turns up in the saved list next time.
    QStringList args{QStringLiteral("device"), QStringLiteral("wifi"),
                     QStringLiteral("connect"), ssid};
    if (!password.isEmpty())
        args << QStringLiteral("password") << password;

    nm(args, nullptr, JOIN_TIMEOUT_MS);
    setStatusFields(QStringLiteral("CONNECTING"), ssid, QString());
    QTimer::singleShot(2000, this, &WifiManager::refreshStatus);
}

void WifiManager::forgetNetwork(const QString &ssid)
{
    nm({QStringLiteral("connection"), QStringLiteral("delete"),
        QStringLiteral("id"), ssid});
    scan();
}

void WifiManager::disconnectWifi()
{
    // Turning the radio off, not just dropping the link: NetworkManager
    // would reconnect a merely disconnected interface within seconds.
    nm({QStringLiteral("radio"), QStringLiteral("wifi"), QStringLiteral("off")});
    setStatusFields(QStringLiteral("DISCONNECTED"), QString(), QString());
}

void WifiManager::reconnectWifi()
{
    nm({QStringLiteral("radio"), QStringLiteral("wifi"), QStringLiteral("on")});
    setStatusFields(QStringLiteral("CONNECTING"), m_currentSsid, QString());
    QTimer::singleShot(3000, this, &WifiManager::refreshStatus);
}
