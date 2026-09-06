#ifndef DEVICEACTIONS_H
#define DEVICEACTIONS_H

#include <QObject>
#include <QString>

// ---------------------------------------------------------------------------
// DeviceActions
//
// Lets the user leave Anki and get the stock reMarkable notes UI back without
// needing a PC and an SSH session. Anki and xochitl cannot run at once: both
// want the framebuffer, so handing over means starting xochitl and quitting.
//
// Also owns idle suspend. Idle sleep on this device is xochitl's job, and
// xochitl is stopped while Anki runs -- so without this the tablet simply
// never sleeps and drains its battery overnight.
// ---------------------------------------------------------------------------

class QTimer;

class DeviceActions : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString batteryLevel READ batteryLevel NOTIFY batteryChanged)
    Q_PROPERTY(bool charging        READ charging     NOTIFY batteryChanged)

public:
    explicit DeviceActions(QObject *parent = nullptr);

    QString batteryLevel() const { return m_batteryLevel; }
    bool charging() const { return m_charging; }

    // Start xochitl and quit, returning the tablet to normal use.
    Q_INVOKABLE void exitToNotes();
    // Reboot. From a powered-off or rebooted state the launcher comes back,
    // which is how you get from the notes UI back into Anki without a PC.
    Q_INVOKABLE void rebootDevice();
    // Suspend now, as the power button would.
    Q_INVOKABLE void suspendDevice();
    // Power off completely. The only state that draws no battery at all.
    Q_INVOKABLE void powerOffDevice();

    // Any input anywhere counts as activity; watching qApp avoids having to
    // thread a "wake up" call through every screen in the QML.
    bool eventFilter(QObject *watched, QEvent *event) override;

signals:
    void batteryChanged();

private slots:
    void refreshBattery();
    void onIdleTimeout();

private:
    QString m_batteryLevel = QStringLiteral("?");
    bool    m_charging = false;

    QTimer *m_idleTimer = nullptr;
};

#endif // DEVICEACTIONS_H
