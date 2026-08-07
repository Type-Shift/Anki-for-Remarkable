#include "deviceactions.h"

#include <QCoreApplication>
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

DeviceActions::DeviceActions(QObject *parent)
    : QObject(parent)
{
    refreshBattery();
    auto *t = new QTimer(this);
    t->setInterval(60000);
    connect(t, &QTimer::timeout, this, &DeviceActions::refreshBattery);
    t->start();
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
