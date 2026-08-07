#include "offlineclient.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QVariantMap>

namespace {
constexpr int  QUEUE_VERSION = 1;
const char    *BATCH_FILE    = "anki-batch.json";
const char    *QUEUE_FILE    = "anki-queue.json";
}

OfflineAnkiClient::OfflineAnkiClient(QObject *parent)
    : QObject(parent)
{
    const QString home = QDir::homePath();
    m_batchPath = home + QLatin1Char('/') + QLatin1String(BATCH_FILE);
    m_queuePath = home + QLatin1Char('/') + QLatin1String(QUEUE_FILE);

    setCurrentState(QStringLiteral("LOADING"));
    setStatusMessage(QStringLiteral("Loading cards..."));
    loadDecks();
}

// --- state helpers ----------------------------------------------------------

void OfflineAnkiClient::setCurrentState(const QString &s)
{
    if (m_currentState == s) return;
    m_currentState = s;
    emit currentStateChanged();
}

void OfflineAnkiClient::setStatusMessage(const QString &s)
{
    if (m_statusMessage == s) return;
    m_statusMessage = s;
    emit statusMessageChanged();
}

void OfflineAnkiClient::setError(const QString &msg)
{
    m_errorMessage = msg;
    emit errorMessageChanged();
    setCurrentState(QStringLiteral("ERROR"));
}

// --- loading ----------------------------------------------------------------

bool OfflineAnkiClient::loadBatch()
{
    QFile f(m_batchPath);
    if (!f.exists()) {
        setError(QStringLiteral(
            "No cards on the device yet.\n\n"
            "Export a batch from the PC:\n"
            "  rmanki.py export --out anki-batch.json\n"
            "then copy it to %1").arg(m_batchPath));
        return false;
    }
    if (!f.open(QIODevice::ReadOnly)) {
        setError(QStringLiteral("Cannot read %1: %2").arg(m_batchPath, f.errorString()));
        return false;
    }

    QJsonParseError perr{};
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &perr);
    f.close();

    if (perr.error != QJsonParseError::NoError || !doc.isObject()) {
        setError(QStringLiteral("Batch file is corrupt: %1").arg(perr.errorString()));
        return false;
    }

    const QJsonObject root = doc.object();
    m_batchDeckName = root.value(QStringLiteral("deck")).toString(QStringLiteral("Offline"));

    m_cards.clear();
    const QJsonArray arr = root.value(QStringLiteral("cards")).toArray();
    for (const QJsonValue &v : arr) {
        const QJsonObject o = v.toObject();
        OfflineCard c;
        // Card ids exceed 2^31, so they must be read as doubles and cast,
        // not toInt().
        c.cardId    = static_cast<qint64>(o.value(QStringLiteral("card_id")).toDouble());
        c.question  = o.value(QStringLiteral("question")).toString();
        c.answer    = o.value(QStringLiteral("answer")).toString();
        c.statesB64 = o.value(QStringLiteral("states_b64")).toString();
        for (const QJsonValue &b : o.value(QStringLiteral("buttons")).toArray())
            c.buttons << b.toString();
        if (c.cardId != 0)
            m_cards.append(c);
    }

    if (m_cards.isEmpty()) {
        setError(QStringLiteral("The batch file contains no cards."));
        return false;
    }
    return true;
}

bool OfflineAnkiClient::loadExistingQueue()
{
    m_answeredIds.clear();
    m_queuedAnswers.clear();

    QFile f(m_queuePath);
    if (!f.exists()) return true;          // nothing reviewed yet
    if (!f.open(QIODevice::ReadOnly)) {
        qWarning() << "cannot read queue:" << f.errorString();
        return false;
    }

    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    f.close();
    if (!doc.isObject()) return false;

    for (const QJsonValue &v : doc.object().value(QStringLiteral("answers")).toArray()) {
        const QJsonObject o = v.toObject();
        const qint64 cid = static_cast<qint64>(o.value(QStringLiteral("card_id")).toDouble());
        if (cid == 0) continue;
        m_answeredIds.insert(cid);
        m_queuedAnswers.append(o.toVariantMap());
    }
    return true;
}

bool OfflineAnkiClient::persistQueue()
{
    QJsonArray answers;
    for (const QVariant &v : m_queuedAnswers)
        answers.append(QJsonObject::fromVariantMap(v.toMap()));

    QJsonObject root;
    root.insert(QStringLiteral("version"), QUEUE_VERSION);
    root.insert(QStringLiteral("answers"), answers);

    // QSaveFile writes to a temp file and renames, so a crash or a battery
    // death mid-write cannot leave a truncated queue. commit() fsyncs.
    QSaveFile out(m_queuePath);
    if (!out.open(QIODevice::WriteOnly)) {
        qWarning() << "cannot open queue for write:" << out.errorString();
        return false;
    }
    out.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
    if (!out.commit()) {
        qWarning() << "queue commit failed:" << out.errorString();
        return false;
    }
    return true;
}

// --- deck list --------------------------------------------------------------

int OfflineAnkiClient::pendingCount() const
{
    int n = 0;
    for (const OfflineCard &c : m_cards)
        if (!m_answeredIds.contains(c.cardId)) ++n;
    return n;
}

void OfflineAnkiClient::rebuildDeckData()
{
    m_deckData.clear();
    QVariantMap deck;
    deck.insert(QStringLiteral("title"),       m_batchDeckName);
    deck.insert(QStringLiteral("visible"),     true);
    deck.insert(QStringLiteral("indent"),      0);
    deck.insert(QStringLiteral("hasChildren"), false);
    deck.insert(QStringLiteral("collapsed"),   m_deckCollapsed);
    // The PC already applied deck limits when building the batch, so every
    // pending card is simply "due" from the tablet's point of view.
    deck.insert(QStringLiteral("newC"),  0);
    deck.insert(QStringLiteral("learnC"), 0);
    deck.insert(QStringLiteral("dueC"),  pendingCount());
    m_deckData.append(deck);
    emit deckDataChanged();
}

void OfflineAnkiClient::loadDecks()
{
    setCurrentState(QStringLiteral("LOADING"));
    setStatusMessage(QStringLiteral("Reading cards..."));

    if (!loadBatch()) return;      // loadBatch() already set the error state
    loadExistingQueue();

    m_cardsReviewed = m_answeredIds.size();
    emit cardsReviewedChanged();

    m_currentTotal = m_cards.size();
    emit currentTotalChanged();

    m_currentRemaining = pendingCount();
    emit currentRemainingChanged();

    rebuildDeckData();

    if (m_currentRemaining == 0) {
        setCurrentState(QStringLiteral("DONE"));
        return;
    }
    setCurrentState(QStringLiteral("DECKS"));
}

void OfflineAnkiClient::toggleDeck(int index)
{
    Q_UNUSED(index)
    m_deckCollapsed = !m_deckCollapsed;
    rebuildDeckData();
}

// --- studying ---------------------------------------------------------------

void OfflineAnkiClient::startStudy(int index)
{
    Q_UNUSED(index)

    m_currentDeckName = m_batchDeckName;
    emit currentDeckNameChanged();

    m_index = 0;
    showNextCard();
}

void OfflineAnkiClient::showNextCard()
{
    // Skip anything already answered, so a restart resumes where we left off.
    while (m_index < m_cards.size() && m_answeredIds.contains(m_cards[m_index].cardId))
        ++m_index;

    if (m_index >= m_cards.size()) {
        m_currentRemaining = 0;
        emit currentRemainingChanged();
        setCurrentState(QStringLiteral("DONE"));
        return;
    }

    const OfflineCard &c = m_cards[m_index];

    m_currentFront = c.question;
    emit currentFrontChanged();

    m_currentBack = c.answer;
    emit currentBackChanged();

    m_currentButtonLabels = c.buttons;
    emit currentButtonLabelsChanged();

    m_currentRemaining = pendingCount();
    emit currentRemainingChanged();

    m_cardTimer.start();
    setCurrentState(QStringLiteral("STUDY"));
}

void OfflineAnkiClient::answerCard(int button)
{
    if (m_index < 0 || m_index >= m_cards.size()) return;
    if (button < 1 || button > 4) return;

    const OfflineCard &c = m_cards[m_index];

    QVariantMap entry;
    entry.insert(QStringLiteral("card_id"),     c.cardId);
    entry.insert(QStringLiteral("rating"),      button);
    entry.insert(QStringLiteral("answered_at"), QDateTime::currentSecsSinceEpoch());
    entry.insert(QStringLiteral("time_taken_ms"),
                 m_cardTimer.isValid() ? qMin<qint64>(m_cardTimer.elapsed(), 600000) : 0);
    entry.insert(QStringLiteral("states_b64"),  c.statesB64);

    m_queuedAnswers.append(entry);
    m_answeredIds.insert(c.cardId);

    // Persist before advancing. RmAnki's failure mode was losing reviews
    // silently; here the answer is on disk before the UI moves on, and a
    // write failure is surfaced rather than logged and forgotten.
    if (!persistQueue()) {
        m_queuedAnswers.removeLast();
        m_answeredIds.remove(c.cardId);
        setError(QStringLiteral(
            "Could not save your answer to %1.\n\n"
            "Nothing has been lost, but reviewing cannot continue safely "
            "until the device has free space.").arg(m_queuePath));
        return;
    }

    m_cardsReviewed = m_answeredIds.size();
    emit cardsReviewedChanged();

    ++m_index;
    showNextCard();
}

void OfflineAnkiClient::login(const QString &email, const QString &password)
{
    Q_UNUSED(email)
    Q_UNUSED(password)
    // Nothing to authenticate against offline; go straight to the cards.
    loadDecks();
}
