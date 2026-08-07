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
// ---------------------------------------------------------------------------

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

signals:
    void batteryChanged();

private slots:
    void refreshBattery();

private:
    QString m_batteryLevel = QStringLiteral("?");
    bool    m_charging = false;
};

#endif // DEVICEACTIONS_H
