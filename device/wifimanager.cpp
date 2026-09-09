#include "wifimanager.h"

#include <QDebug>
#include <QProcess>
#include <QTimer>
#include <QVariantMap>

#include <memory>

namespace {
const char *IFACE = "wlan0";
constexpr int CMD_TIMEOUT_MS  = 8000;
constexpr int JOIN_TIMEOUT_MS = 25000;  // association plus DHCP
constexpr int POLL_MS         = 4000;   // status and the cached network list
constexpr int RESCAN_EVERY    = 5;      // polls between forced rescans (~20s)

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
    m_pollTimer = new QTimer(this);
    m_pollTimer->setInterval(POLL_MS);
    connect(m_pollTimer, &QTimer::timeout, this, &WifiManager::poll);
    m_pollTimer->start();

    // The radio stays on. There is no battery case for leaving it off: the
    // tablet suspends between uses and the chip powers down with it.
    run({QStringLiteral("radio"), QStringLiteral("wifi"), QStringLiteral("on")});

    poll();
}

// --- command plumbing -------------------------------------------------------

void WifiManager::run(const QStringList &args, int timeoutMs, Handler done)
{
    // Asynchronous on purpose. These used to block the GUI thread on
    // waitForFinished, so every poll stuttered the display and a join froze
    // the whole app for as long as association and DHCP took -- up to a
    // quarter of a minute of a tablet that appeared to have crashed.
    auto *p = new QProcess(this);

    // errorOccurred and finished can both fire for one process, so the
    // callback is guarded. Shared rather than raw: freeing the flag on the
    // first call would leave the second reading freed memory.
    auto called = std::make_shared<bool>(false);
    const auto complete = [p, called, done](bool ok, const QString &out) {
        if (*called) return;
        *called = true;
        if (done) done(ok, out);
        p->deleteLater();
    };

    connect(p, &QProcess::finished, this,
            [this, p, complete](int code, QProcess::ExitStatus status) {
        const QString out = QString::fromUtf8(p->readAllStandardOutput());
        const bool ok = (status == QProcess::NormalExit && code == 0);
        if (!ok) {
            const QString err = QString::fromUtf8(p->readAllStandardError()).trimmed();
            if (!err.isEmpty()) setWifiError(err.section(QLatin1Char('\n'), -1));
        }
        complete(ok, out);
    });

    connect(p, &QProcess::errorOccurred, this, [this, complete](QProcess::ProcessError e) {
        if (e == QProcess::FailedToStart)
            setWifiError(QStringLiteral("nmcli not available on this device"));
        complete(false, QString());
    });

    // A hung nmcli would otherwise leak a process and never call back.
    QTimer::singleShot(timeoutMs, p, [p]() {
        if (p->state() != QProcess::NotRunning) p->kill();
    });

    p->start(QStringLiteral("nmcli"), args);
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

// --- polling ----------------------------------------------------------------

void WifiManager::poll()
{
    refreshStatus();
    refreshNetworks();

    // NetworkManager ages its scan cache out on its own, but only rescans
    // when something asks. Nudging it periodically is what makes the list
    // fill in by itself instead of waiting for a tap on "scan".
    if (++m_pollsSinceScan >= RESCAN_EVERY) {
        m_pollsSinceScan = 0;
        run({QStringLiteral("device"), QStringLiteral("wifi"), QStringLiteral("rescan")});
    }
}

// --- status -----------------------------------------------------------------

void WifiManager::refreshStatus()
{
    run({QStringLiteral("-t"), QStringLiteral("-f"),
         QStringLiteral("GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS"),
         QStringLiteral("device"), QStringLiteral("show"), QLatin1String(IFACE)},
        CMD_TIMEOUT_MS,
        [this](bool ok, const QString &out) {
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

        // NetworkManager device states: 100 activated, anything from
        // preparing (40) up to secondaries (90) is on its way, below is down.
        QString state;
        if (deviceState >= 100)     state = QStringLiteral("COMPLETED");
        else if (deviceState >= 40) state = QStringLiteral("CONNECTING");
        else                        state = QStringLiteral("DISCONNECTED");

        setStatusFields(state, ssid, ip);
    });

    // No reconnect loop here on purpose. The old firmware left that to us;
    // NetworkManager does it itself, and polling it into a fight produced a
    // reconnect every eight seconds against a link that was already up.
}

// --- scanning ---------------------------------------------------------------

void WifiManager::scan()
{
    setWifiError(QString());
    setScanning(true);
    m_pollsSinceScan = 0;
    run({QStringLiteral("device"), QStringLiteral("wifi"), QStringLiteral("rescan")},
        CMD_TIMEOUT_MS,
        [this](bool, const QString &) {
        setScanning(false);
        refreshNetworks();
    });
}

void WifiManager::refreshNetworks()
{
    // Saved connections first, so the list can mark which need no password.
    run({QStringLiteral("-t"), QStringLiteral("-f"), QStringLiteral("NAME,TYPE"),
         QStringLiteral("connection"), QStringLiteral("show")},
        CMD_TIMEOUT_MS,
        [this](bool ok, const QString &savedOut) {
        QStringList saved;
        if (ok) {
            const QStringList savedLines =
                savedOut.split(QLatin1Char('\n'), Qt::SkipEmptyParts);
            for (const QString &line : savedLines) {
                const QStringList f = splitTerse(line);
                if (f.size() >= 2 && f.at(1).contains(QLatin1String("wireless")))
                    saved << f.at(0);
            }
        }

        // Reads NetworkManager's cache, so this is cheap enough to poll.
        run({QStringLiteral("-t"), QStringLiteral("-f"),
             QStringLiteral("SSID,SIGNAL,SECURITY"),
             QStringLiteral("device"), QStringLiteral("wifi"), QStringLiteral("list")},
            CMD_TIMEOUT_MS,
            [this, saved](bool listOk, const QString &out) {
            if (listOk) rebuildNetworks(out, saved);
        });
    });
}

void WifiManager::rebuildNetworks(const QString &scanOutput, const QStringList &saved)
{
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

    QVariantList built;
    for (const QVariantMap &n : sorted)
        built.append(n);

    // Rebuilding an identical list every poll would reset the scroll position
    // under the user's finger, which is half of what read as stutter.
    if (built == m_networks) return;
    m_networks = built;
    emit networksChanged();
}

// --- joining ----------------------------------------------------------------

void WifiManager::connectToSaved(const QString &ssid)
{
    setWifiError(QString());
    setStatusFields(QStringLiteral("CONNECTING"), ssid, QString());
    run({QStringLiteral("connection"), QStringLiteral("up"),
         QStringLiteral("id"), ssid},
        JOIN_TIMEOUT_MS,
        [this](bool, const QString &) { refreshStatus(); });
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

    setStatusFields(QStringLiteral("CONNECTING"), ssid, QString());
    run(args, JOIN_TIMEOUT_MS, [this](bool, const QString &) { refreshStatus(); });
}

void WifiManager::forgetNetwork(const QString &ssid)
{
    run({QStringLiteral("connection"), QStringLiteral("delete"),
         QStringLiteral("id"), ssid},
        CMD_TIMEOUT_MS,
        [this](bool, const QString &) { refreshNetworks(); });
}

void WifiManager::disconnectWifi()
{
    // Turning the radio off, not just dropping the link: NetworkManager
    // would reconnect a merely disconnected interface within seconds.
    setStatusFields(QStringLiteral("DISCONNECTED"), QString(), QString());
    run({QStringLiteral("radio"), QStringLiteral("wifi"), QStringLiteral("off")});
}

void WifiManager::reconnectWifi()
{
    setStatusFields(QStringLiteral("CONNECTING"), m_currentSsid, QString());
    run({QStringLiteral("radio"), QStringLiteral("wifi"), QStringLiteral("on")},
        CMD_TIMEOUT_MS,
        [this](bool, const QString &) { refreshStatus(); });
}
