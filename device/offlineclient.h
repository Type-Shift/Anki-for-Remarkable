#ifndef OFFLINECLIENT_H
#define OFFLINECLIENT_H

#include <QObject>
#include <QSet>
#include <QString>
#include <QStringList>
#include <QVariantList>
#include <QElapsedTimer>

// ---------------------------------------------------------------------------
// OfflineAnkiClient
//
// Adapter between the QML UI and Anki's own Rust backend (see ankicore.h).
//
// It used to carry a scheduler of sorts: a batch of cards exported by the PC,
// plus a learning queue driven by parsing Anki's interval labels. That was a
// good approximation but it could not work out what an interval becomes after
// a step, so multi-step learning drifted from the desktop.
//
// All of that is gone. Deck counts, card selection, rendering and scheduling
// now come from rslib against a real collection.anki2 on the device, so the
// tablet and the desktop agree exactly.
//
// The QML-facing surface is unchanged, so Main.qml did not have to move.
// ---------------------------------------------------------------------------

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
    Q_PROPERTY(int pendingAnswers      READ pendingAnswers  NOTIFY pendingAnswersChanged)
    Q_PROPERTY(QString batchInfo       READ batchInfo       NOTIFY batchInfoChanged)

public:
    explicit OfflineAnkiClient(QObject *parent = nullptr);
    ~OfflineAnkiClient() override;

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
    // Nothing is queued any more: answers land in the collection immediately.
    int pendingAnswers() const { return 0; }
    QString batchInfo() const { return m_batchInfo; }

    Q_INVOKABLE void login(const QString &email, const QString &password);
    Q_INVOKABLE void loadDecks();
    Q_INVOKABLE void startStudy(int index);
    Q_INVOKABLE void answerCard(int button);
    Q_INVOKABLE void toggleDeck(int index);
    Q_INVOKABLE void checkForNewCards();
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

private:
    void setCurrentState(const QString &s);
    void setStatusMessage(const QString &s);
    void setError(const QString &msg);
    void clearError();

    // Calls into ankicore and parses the JSON reply. Returns an empty object
    // and sets the error state when the call fails.
    QVariantMap call(char *rawJson, const QString &context);

    bool openCollection();
    void rebuildDeckData();      // from m_deckNodes plus local collapse state
    void showNextCard();

    struct DeckNode {
        qint64  id = 0;
        QString name;            // full "Parent::Child" path
        int     level = 0;
        bool    hasChildren = false;
        int     newC = 0;
        int     learnC = 0;
        int     reviewC = 0;
        int     due = 0;
    };

    QString m_collectionPath;
    bool    m_collectionOpen = false;

    QList<DeckNode> m_deckNodes;     // full tree, unpruned
    QSet<QString>   m_collapsed;     // by full deck name, seeded from Anki
    QList<qint64>   m_visibleDeckIds;// parallel to m_deckData, for invokables
    QStringList     m_visibleDeckNames;

    qint64 m_currentDeckId = 0;
    qint64 m_currentCardId = 0;
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
    QString      m_batchInfo;
};

#endif // OFFLINECLIENT_H
