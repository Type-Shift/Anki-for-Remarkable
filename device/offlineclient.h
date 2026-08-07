#ifndef OFFLINECLIENT_H
#define OFFLINECLIENT_H

#include <QObject>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QVector>
#include <QSet>
#include <QElapsedTimer>

class QFileSystemWatcher;
class QTimer;

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
    QString     deck;
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
    // Answers reviewed offline that the PC has not collected yet.
    Q_PROPERTY(int pendingAnswers      READ pendingAnswers  NOTIFY pendingAnswersChanged)
    // Human-readable description of the batch currently on the device.
    Q_PROPERTY(QString batchInfo       READ batchInfo       NOTIFY batchInfoChanged)

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
    int pendingAnswers() const { return m_queuedAnswers.size(); }
    QString batchInfo() const { return m_batchInfo; }

    // Same invokables Main.qml calls. login() is retained only so the QML
    // binding resolves; there is nothing to log into offline.
    Q_INVOKABLE void login(const QString &email, const QString &password);
    Q_INVOKABLE void loadDecks();
    Q_INVOKABLE void startStudy(int index);
    Q_INVOKABLE void answerCard(int button);
    Q_INVOKABLE void toggleDeck(int index);
    // Re-read the batch from disk. Safe to call from the finished screen so
    // the user is never stranded there after the PC pushes new cards.
    Q_INVOKABLE void checkForNewCards();
    // Back to the launcher chooser.
    Q_INVOKABLE void goHome();

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
    void pendingAnswersChanged();
    void batchInfoChanged();

private slots:
    // Fires when the PC pushes a new batch file, so new cards appear without
    // needing the app restarted.
    void onBatchPathChanged();

private:
    void setCurrentState(const QString &s);
    void setStatusMessage(const QString &s);
    void setError(const QString &msg);

    bool loadBatch();          // read the PC-written batch file
    bool loadExistingQueue();  // resume: skip cards already answered
    QStringList deckNames() const;               // decks with cards still pending
    int  pendingInDeck(const QString &deck) const;
    bool inActiveDeck(const OfflineCard &c) const;
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

    QSet<QString> m_collapsedDecks;
    bool m_collapseInitialised = false;   // parents start collapsed, once
    QStringList   m_visibleDecks;   // parallel to m_deckData, for startStudy()
    QString m_activeDeck;           // deck currently being studied
    QString m_batchDeckName;
    QString m_batchInfo;
    qint64  m_batchExportedAt = 0;

    QFileSystemWatcher *m_watcher = nullptr;
    QTimer *m_reloadDebounce = nullptr;
};

#endif // OFFLINECLIENT_H
