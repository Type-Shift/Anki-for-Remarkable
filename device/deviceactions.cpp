#include "deviceactions.h"

#include <QCoreApplication>
#include <QEvent>
#include <QGuiApplication>
#include <QDebug>
#include <QFile>
#include <QProcess>
#include <QTimer>

namespace {
// reMarkable 1 exposes the gauge here; the path differs on other models, so
// a miss is not an error, just an unknown reading.
const char *CAPACITY_PATHS[] = {
    "/sys/class/power_supply/bq27441-0/capacity",
    "/sys/class/power_supply/max77818_battery/capacity",
    "/sys/class/power_supply/battery/capacity",
};
const char *STATUS_PATHS[] = {
    "/sys/class/power_supply/bq27441-0/status",
    "/sys/class/power_supply/max77818_battery/status",
    "/sys/class/power_supply/battery/status",
};

QString readFirst(const char *const paths[], int count)
{
    for (int i = 0; i < count; ++i) {
        QFile f(QLatin1String(paths[i]));
        if (f.open(QIODevice::ReadOnly))
            return QString::fromUtf8(f.readAll()).trimmed();
    }
    return QString();
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
    t->setInterval(60000);
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
    const QString cap = readFirst(CAPACITY_PATHS, 3);
    const QString st  = readFirst(STATUS_PATHS, 3);

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

void DeviceActions::rebootDevice()
{
    QProcess::startDetached(QStringLiteral("systemctl"), {QStringLiteral("reboot")});
}
