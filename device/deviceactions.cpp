#include "deviceactions.h"

#include <QCoreApplication>
#include <QEvent>
#include <QGuiApplication>
#include <QDebug>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QProcess>
#include <QTimer>

namespace {
QString readTrimmed(const QString &path)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly)) return QString();
    return QString::fromUtf8(f.readAll()).trimmed();
}

// The battery's sysfs directory, found rather than hardcoded.
//
// A fixed list of candidate paths read whichever one happened to open first,
// which is not necessarily the battery: a charger is a power supply too, and
// a firmware update is free to rename any of them. Ask the kernel which
// supply is the battery instead.
QString batteryDir()
{
    // Cached because it cannot move while the app runs, and walking sysfs
    // every minute is wasted work on a single-core device. A failed lookup
    // caches nothing, so a late-probing driver is still picked up.
    static QString cached;
    if (!cached.isEmpty()) return cached;

    const QString base = QStringLiteral("/sys/class/power_supply");
    const QStringList supplies =
        QDir(base).entryList(QDir::Dirs | QDir::NoDotAndDotDot);

    for (const QString &name : supplies) {
        const QString dir = base + QLatin1Char('/') + name;
        if (readTrimmed(dir + QStringLiteral("/type")) != QLatin1String("Battery"))
            continue;
        if (!QFile::exists(dir + QStringLiteral("/capacity")))
            continue;
        cached = dir;
        break;
    }
    return cached;
}
}

namespace {
// Matches the stock reMarkable idle timeout closely enough that the tablet
// behaves the way the user expects it to.
constexpr int IDLE_SUSPEND_MS = 10 * 60 * 1000;
}

DeviceActions::DeviceActions(QObject *parent)
    : QObject(parent)
{
    refreshBattery();
    auto *t = new QTimer(this);
    // Half a minute. A minute was long enough that the reading visibly
    // lagged the real level, especially right after a resume.
    t->setInterval(30000);
    connect(t, &QTimer::timeout, this, &DeviceActions::refreshBattery);
    t->start();

    // Idle suspend. xochitl normally does this, and it is stopped while Anki
    // runs, so without it the tablet stays awake indefinitely.
    m_idleTimer = new QTimer(this);
    m_idleTimer->setSingleShot(true);
    m_idleTimer->setInterval(IDLE_SUSPEND_MS);
    connect(m_idleTimer, &QTimer::timeout, this, &DeviceActions::onIdleTimeout);
    m_idleTimer->start();

    if (qApp) qApp->installEventFilter(this);
}

bool DeviceActions::eventFilter(QObject *watched, QEvent *event)
{
    switch (event->type()) {
    case QEvent::TouchBegin:
    case QEvent::TouchUpdate:
    case QEvent::TouchEnd:
    case QEvent::MouseButtonPress:
    case QEvent::MouseButtonRelease:
    case QEvent::MouseMove:
    case QEvent::KeyPress:
        if (m_idleTimer) m_idleTimer->start();   // restart the countdown
        // The poll timer is frozen while the device is suspended, so the
        // first thing seen on waking was a reading taken before the sleep --
        // hours stale after a night on the shelf. Re-read on the touch that
        // woke it, throttled so a scroll does not hammer sysfs.
        if (!m_sinceBattery.isValid() || m_sinceBattery.elapsed() > 15000)
            refreshBattery();
        break;
    default:
        break;
    }
    return QObject::eventFilter(watched, event);
}

void DeviceActions::onIdleTimeout()
{
    // Charging is the one case where staying awake is the friendlier
    // behaviour, and it also keeps the tablet reachable while it sits on a
    // cable.
    if (m_charging) {
        m_idleTimer->start();
        return;
    }

    qInfo() << "idle: suspending";
    suspendDevice();
}

void DeviceActions::suspendDevice()
{
    // systemctl honours block inhibitors, so a deploy in progress will
    // refuse this rather than dropping the link mid-transfer.
    QProcess::startDetached(QStringLiteral("systemctl"), {QStringLiteral("suspend")});

    // Start counting again for when it wakes.
    if (m_idleTimer) m_idleTimer->start();
}

void DeviceActions::refreshBattery()
{
    m_sinceBattery.restart();

    const QString dir = batteryDir();
    const QString cap = dir.isEmpty() ? QString()
                                      : readTrimmed(dir + QStringLiteral("/capacity"));
    const QString st  = dir.isEmpty() ? QString()
                                      : readTrimmed(dir + QStringLiteral("/status"));

    const QString level = cap.isEmpty() ? QStringLiteral("?") : cap + QStringLiteral("%");
    const bool chg = st.compare(QLatin1String("Charging"), Qt::CaseInsensitive) == 0;

    if (level == m_batteryLevel && chg == m_charging) return;
    m_batteryLevel = level;
    m_charging = chg;
    emit batteryChanged();
}

void DeviceActions::exitToNotes()
{
    // Logged because a silent exit-0 is otherwise indistinguishable from a
    // crash: the service just goes inactive. If this line appears without
    // anyone touching the tablet, a stray input event reached the NOTES row.
    qInfo() << "exitToNotes(): starting xochitl and quitting";

    // Start xochitl before quitting. When launched by anki-launcher.service
    // systemd would do this anyway via ExecStopPost, but doing it here means
    // a manually started app behaves the same.
    QProcess::startDetached(QStringLiteral("systemctl"),
                            {QStringLiteral("start"), QStringLiteral("xochitl")});

    // Give xochitl a moment to claim the framebuffer before we release it.
    QTimer::singleShot(1200, qApp, &QCoreApplication::quit);
}

void DeviceActions::powerOffDevice()
{
    // The idle timer is deliberately not restarted: there is nothing to come
    // back to. suspendDevice restarts it because the app survives a suspend.
    QProcess::startDetached(QStringLiteral("systemctl"), {QStringLiteral("poweroff")});
}

void DeviceActions::rebootDevice()
{
    QProcess::startDetached(QStringLiteral("systemctl"), {QStringLiteral("reboot")});
}
