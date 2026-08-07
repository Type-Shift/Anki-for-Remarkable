#ifndef OFFLINECLIENT_H
#define OFFLINECLIENT_H

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>
#include <QSet>
#include <QElapsedTimer>

// ---------------------------------------------------------------------------
// OfflineAnkiClient
//
// Drop-in replacement for AnkiClient that never touches the network. Cards
// come from a batch file written by the PC; answers are appended to a queue
// file the PC drains on reconnect.
//
// Exposes exactly the surface Main.qml binds to, so the UI is unchanged.
// ---------------------------------------------------------------------------

struct OfflineCard {
    qint64      cardId = 0;
    QString     question;
    QString     answer;
    QStringList buttons;
    QString     statesB64;   // opaque to us; handed straight back to the PC
};

class OfflineAnkiClient : public QObject
{
    Q_OBJECT

    Q_PROPERTY(QString currentState    READ currentState    NOTIFY currentStateChanged)
    Q_PROPERTY(QVariantList deckData   READ deckData        NOTIFY deckDataChanged)
    Q_PROPERTY(QString currentDeckName READ currentDeckName NOTIFY currentDeckNameChanged)
    Q_PROPERTY(QString currentFront    READ currentFront    NOTIFY currentFrontChanged)
    Q_PROPERTY(QString currentBack     READ currentBack     NOTIFY currentBackChanged)
    Q_PROPERTY(QStringList currentButtonLabels READ currentButtonLabels NOTIFY currentButtonLabelsChanged)
    Q_PROPERTY(int currentRemaining    READ currentRemaining NOTIFY currentRemainingChanged)
    Q_PROPERTY(int currentTotal        READ currentTotal    NOTIFY currentTotalChanged)
    Q_PROPERTY(int cardsReviewed       READ cardsReviewed   NOTIFY cardsReviewedChanged)
    Q_PROPERTY(QString statusMessage   READ statusMessage   NOTIFY statusMessageChanged)
    Q_PROPERTY(QString errorMessage    READ errorMessage    NOTIFY errorMessageChanged)

public:
    explicit OfflineAnkiClient(QObject *parent = nullptr);

    QString currentState() const { return m_currentState; }
    QVariantList deckData() const { return m_deckData; }
    QString currentDeckName() const { return m_currentDeckName; }
    QString currentFront() const { return m_currentFront; }
    QString currentBack() const { return m_currentBack; }
    QStringList currentButtonLabels() const { return m_currentButtonLabels; }
    int currentRemaining() const { return m_currentRemaining; }
    int currentTotal() const { return m_currentTotal; }
    int cardsReviewed() const { return m_cardsReviewed; }
    QString statusMessage() const { return m_statusMessage; }
    QString errorMessage() const { return m_errorMessage; }

    // Same invokables Main.qml calls. login() is retained only so the QML
    // binding resolves; there is nothing to log into offline.
    Q_INVOKABLE void login(const QString &email, const QString &password);
    Q_INVOKABLE void loadDecks();
    Q_INVOKABLE void startStudy(int index);
    Q_INVOKABLE void answerCard(int button);
    Q_INVOKABLE void toggleDeck(int index);

signals:
    void currentStateChanged();
    void deckDataChanged();
    void currentDeckNameChanged();
    void currentFrontChanged();
    void currentBackChanged();
    void currentButtonLabelsChanged();
    void currentRemainingChanged();
    void currentTotalChanged();
    void cardsReviewedChanged();
    void statusMessageChanged();
    void errorMessageChanged();

private:
    void setCurrentState(const QString &s);
    void setStatusMessage(const QString &s);
    void setError(const QString &msg);

    bool loadBatch();          // read the PC-written batch file
    bool loadExistingQueue();  // resume: skip cards already answered
    bool persistQueue();       // atomic + fsync; a lost answer is the one
                               // failure mode this whole project exists to fix
    void showNextCard();
    void rebuildDeckData();
    int  pendingCount() const;

    QString m_batchPath;
    QString m_queuePath;

    QVector<OfflineCard> m_cards;
    QSet<qint64>         m_answeredIds;
    QVariantList         m_queuedAnswers;   // serialised straight to JSON

    int m_index = 0;
    QElapsedTimer m_cardTimer;

    QString      m_currentState;
    QVariantList m_deckData;
    QString      m_currentDeckName;
    QString      m_currentFront;
    QString      m_currentBack;
    QStringList  m_currentButtonLabels;
    int          m_currentRemaining = 0;
    int          m_currentTotal     = 0;
    int          m_cardsReviewed    = 0;
    QString      m_statusMessage;
    QString      m_errorMessage;

    bool m_deckCollapsed = false;
    QString m_batchDeckName;
};

#endif // OFFLINECLIENT_H
