#include "wifimanager.h"

#include <QDebug>
#include <QProcess>
#include <QRegularExpression>
#include <QTimer>
#include <QVariantMap>

namespace {
const char *IFACE       = "wlan0";
constexpr int WPA_TIMEOUT_MS = 5000;
constexpr int SCAN_WAIT_MS   = 3500;   // wpa_supplicant needs a moment
constexpr int POLL_MS        = 4000;   // refresh status while the panel is open
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

QString WifiManager::wpa(const QStringList &args, bool *ok)
{
    QProcess p;
    QStringList full;
    full << QStringLiteral("-i") << QLatin1String(IFACE);
    full << args;

    p.start(QStringLiteral("wpa_cli"), full);
    if (!p.waitForStarted(WPA_TIMEOUT_MS)) {
        if (ok) *ok = false;
        setWifiError(QStringLiteral("wpa_cli not available on this device"));
        return QString();
    }
    if (!p.waitForFinished(WPA_TIMEOUT_MS)) {
        p.kill();
        if (ok) *ok = false;
        setWifiError(QStringLiteral("wpa_cli timed out"));
        return QString();
    }

    const QString out = QString::fromUtf8(p.readAllStandardOutput());
    if (ok) *ok = !out.trimmed().endsWith(QLatin1String("FAIL"));
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
    const QString out = wpa({QStringLiteral("status")}, &ok);
    if (!ok && out.isEmpty()) {
        setStatusFields(QStringLiteral("UNAVAILABLE"), QString(), QString());
        return;
    }

    QString state, ssid, ip;
    const QStringList lines = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (const QString &line : lines) {
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq < 0) continue;
        const QString key = line.left(eq).trimmed();
        const QString val = line.mid(eq + 1).trimmed();
        if (key == QLatin1String("wpa_state"))  state = val;
        else if (key == QLatin1String("ssid"))  ssid  = val;
        else if (key == QLatin1String("ip_address")) ip = val;
    }

    if (state.isEmpty()) state = QStringLiteral("DISCONNECTED");
    setStatusFields(state, ssid, ip);
}

// --- scanning ---------------------------------------------------------------

void WifiManager::scan()
{
    setWifiError(QString());
    setScanning(true);
    wpa({QStringLiteral("scan")});
    m_scanTimer->start(SCAN_WAIT_MS);
}

void WifiManager::collectScanResults()
{
    const QString out = wpa({QStringLiteral("scan_results")});
    rebuildNetworks(out);
    setScanning(false);
    refreshStatus();
}

void WifiManager::rebuildNetworks(const QString &scanOutput)
{
    // Saved networks, so the UI can offer one-tap reconnect without a password.
    QStringList saved;
    const QString savedOut = wpa({QStringLiteral("list_networks")});
    const QStringList savedLines = savedOut.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (int i = 1; i < savedLines.size(); ++i) {          // skip header row
        const QStringList f = savedLines.at(i).split(QLatin1Char('\t'));
        if (f.size() >= 2 && !f.at(1).trimmed().isEmpty())
            saved << f.at(1).trimmed();
    }

    // scan_results columns: bssid / frequency / signal level / flags / ssid
    QMap<QString, QVariantMap> best;
    const QStringList lines = scanOutput.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (int i = 1; i < lines.size(); ++i) {               // skip header row
        const QStringList f = lines.at(i).split(QLatin1Char('\t'));
        if (f.size() < 5) continue;

        const QString ssid = f.at(4).trimmed();
        if (ssid.isEmpty()) continue;                      // hidden network

        const int signal  = f.at(2).trimmed().toInt();
        const QString flags = f.at(3);
        const bool secured = flags.contains(QLatin1String("WPA")) ||
                             flags.contains(QLatin1String("WEP"));

        // Same SSID often appears per-band and per-AP; keep the strongest.
        if (best.contains(ssid) && best[ssid].value(QStringLiteral("signal")).toInt() >= signal)
            continue;

        QVariantMap n;
        n.insert(QStringLiteral("ssid"),    ssid);
        n.insert(QStringLiteral("signal"),  signal);
        n.insert(QStringLiteral("secured"), secured);
        n.insert(QStringLiteral("saved"),   saved.contains(ssid));
        n.insert(QStringLiteral("current"), ssid == m_currentSsid);
        // -50 excellent, -90 unusable; map to 0-4 bars for the UI.
        int bars = (signal >= -55) ? 4 : (signal >= -67) ? 3 : (signal >= -75) ? 2 : (signal >= -85) ? 1 : 0;
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

int WifiManager::savedNetworkId(const QString &ssid)
{
    const QString out = wpa({QStringLiteral("list_networks")});
    const QStringList lines = out.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    for (int i = 1; i < lines.size(); ++i) {
        const QStringList f = lines.at(i).split(QLatin1Char('\t'));
        if (f.size() >= 2 && f.at(1).trimmed() == ssid)
            return f.at(0).trimmed().toInt();
    }
    return -1;
}

void WifiManager::connectToSaved(const QString &ssid)
{
    setWifiError(QString());
    const int id = savedNetworkId(ssid);
    if (id < 0) {
        setWifiError(QStringLiteral("%1 is not a saved network").arg(ssid));
        return;
    }
    wpa({QStringLiteral("select_network"), QString::number(id)});
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

    // Reuse the saved entry if we already know this network, so repeated
    // joins don't accumulate duplicates in wpa_supplicant.conf.
    int id = savedNetworkId(ssid);
    if (id < 0) {
        bool ok = false;
        const QString out = wpa({QStringLiteral("add_network")}, &ok);
        id = out.trimmed().split(QLatin1Char('\n')).last().trimmed().toInt(&ok);
        if (!ok || id < 0) {
            setWifiError(QStringLiteral("Could not create a network entry"));
            return;
        }
    }

    // wpa_cli expects string values wrapped in literal double quotes.
    const QString qSsid = QStringLiteral("\"%1\"").arg(ssid);
    wpa({QStringLiteral("set_network"), QString::number(id), QStringLiteral("ssid"), qSsid});

    if (password.isEmpty()) {
        wpa({QStringLiteral("set_network"), QString::number(id),
             QStringLiteral("key_mgmt"), QStringLiteral("NONE")});
    } else {
        const QString qPsk = QStringLiteral("\"%1\"").arg(password);
        wpa({QStringLiteral("set_network"), QString::number(id),
             QStringLiteral("key_mgmt"), QStringLiteral("WPA-PSK")});
        wpa({QStringLiteral("set_network"), QString::number(id),
             QStringLiteral("psk"), qPsk});
    }

    wpa({QStringLiteral("enable_network"), QString::number(id)});
    wpa({QStringLiteral("select_network"), QString::number(id)});
    // update_config=1 is set, so this persists the network across reboots.
    wpa({QStringLiteral("save_config")});

    setStatusFields(QStringLiteral("CONNECTING"), ssid, QString());
    QTimer::singleShot(3000, this, &WifiManager::refreshStatus);
}

void WifiManager::forgetNetwork(const QString &ssid)
{
    const int id = savedNetworkId(ssid);
    if (id < 0) return;
    wpa({QStringLiteral("remove_network"), QString::number(id)});
    wpa({QStringLiteral("save_config")});
    scan();
}

void WifiManager::disconnectWifi()
{
    wpa({QStringLiteral("disconnect")});
    setStatusFields(QStringLiteral("DISCONNECTED"), QString(), QString());
}

void WifiManager::reconnectWifi()
{
    wpa({QStringLiteral("reconnect")});
    setStatusFields(QStringLiteral("CONNECTING"), m_currentSsid, QString());
    QTimer::singleShot(3000, this, &WifiManager::refreshStatus);
}
