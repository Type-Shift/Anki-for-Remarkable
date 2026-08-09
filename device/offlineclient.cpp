#include "offlineclient.h"

#include <QDebug>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QVariantMap>

#include "ankicore.h"

namespace {
// Pushed by pc/collection.ps1. Not derived from QDir::homePath(): systemd
// services inherit no HOME, so that resolves to "/" and the app hunts for the
// collection in the wrong place. Fine over SSH, broken under the launcher.
const char *COLLECTION_PATH = "/home/root/collection.anki2";
}

OfflineAnkiClient::OfflineAnkiClient(QObject *parent)
    : QObject(parent)
    , m_collectionPath(QString::fromLatin1(COLLECTION_PATH))
{
    if (openCollection()) {
        loadDecks();
    }
    // The launcher shows first either way, so a missing collection surfaces
    // as a message on the home screen rather than an empty deck list.
    setCurrentState(QStringLiteral("HOME"));
}

OfflineAnkiClient::~OfflineAnkiClient()
{
    if (m_collectionOpen) {
        // Flush to disk, or the last few answers exist only in the WAL.
        char *r = ankicore_close();
        if (r) ankicore_free_string(r);
    }
}

// --- plumbing ---------------------------------------------------------------

QVariantMap OfflineAnkiClient::call(char *rawJson, const QString &context)
{
    if (!rawJson) {
        setError(QStringLiteral("%1: the Anki backend returned nothing").arg(context));
        return {};
    }

    const QByteArray payload(rawJson);
    ankicore_free_string(rawJson);

    QJsonParseError parseError{};
    const QJsonDocument doc = QJsonDocument::fromJson(payload, &parseError);
    if (doc.isNull() || !doc.isObject()) {
        setError(QStringLiteral("%1: could not read the backend's reply (%2)")
                     .arg(context, parseError.errorString()));
        return {};
    }

    const QJsonObject obj = doc.object();
    if (!obj.value(QStringLiteral("ok")).toBool(false)) {
        setError(QStringLiteral("%1: %2")
                     .arg(context, obj.value(QStringLiteral("error"))
                                       .toString(QStringLiteral("unknown error"))));
        return {};
    }

    return obj.toVariantMap();
}

bool OfflineAnkiClient::openCollection()
{
    if (!QFile::exists(m_collectionPath)) {
        setError(QStringLiteral(
            "No collection on the device yet.\n\n"
            "Run collection.ps1 push on your computer to copy it across."));
        return false;
    }

    const QVariantMap r = call(ankicore_open(m_collectionPath.toUtf8().constData()),
                               QStringLiteral("Opening collection"));
    if (r.isEmpty()) return false;

    m_collectionOpen = true;
    clearError();
    return true;
}

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
    if (m_errorMessage != msg) {
        m_errorMessage = msg;
        emit errorMessageChanged();
    }
    qWarning().noquote() << "anki:" << msg;
}

void OfflineAnkiClient::clearError()
{
    // Without this a single early failure sticks forever: a later success
    // advances the state but the home screen keeps reading errorMessage.
    if (m_errorMessage.isEmpty()) return;
    m_errorMessage.clear();
    emit errorMessageChanged();
}

// --- decks ------------------------------------------------------------------

void OfflineAnkiClient::loadDecks()
{
    if (!m_collectionOpen && !openCollection()) {
        setCurrentState(QStringLiteral("ERROR"));
        return;
    }

    setStatusMessage(QStringLiteral("Reading decks..."));

    const QVariantMap r = call(ankicore_deck_list(), QStringLiteral("Loading decks"));
    if (r.isEmpty()) {
        setCurrentState(QStringLiteral("ERROR"));
        return;
    }

    const bool firstLoad = m_deckNodes.isEmpty();
    m_deckNodes.clear();

    const QVariantList decks = r.value(QStringLiteral("decks")).toList();
    int totalDue = 0;
    for (const QVariant &v : decks) {
        const QVariantMap d = v.toMap();
        DeckNode n;
        n.id          = d.value(QStringLiteral("id")).toLongLong();
        n.name        = d.value(QStringLiteral("name")).toString();
        n.level       = d.value(QStringLiteral("level")).toInt();
        n.hasChildren = d.value(QStringLiteral("has_children")).toBool();
        n.newC        = d.value(QStringLiteral("new")).toInt();
        n.learnC      = d.value(QStringLiteral("learn")).toInt();
        n.reviewC     = d.value(QStringLiteral("review")).toInt();
        n.due         = d.value(QStringLiteral("due")).toInt();
        m_deckNodes.append(n);

        if (n.level == 0) totalDue += n.due;   // top level already includes children

        // Seed collapse from what Anki itself has stored, once. After that the
        // user's taps win, since collapse cannot be written back yet.
        if (firstLoad && d.value(QStringLiteral("collapsed")).toBool())
            m_collapsed.insert(n.name);
    }

    m_currentTotal = totalDue;
    emit currentTotalChanged();

    m_batchInfo = QStringLiteral("Scheduled by Anki %1")
                      .arg(QStringLiteral("25.09"));
    emit batchInfoChanged();

    clearError();
    rebuildDeckData();

    setCurrentState(totalDue > 0 ? QStringLiteral("DECKS")
                                 : QStringLiteral("DONE"));
}

void OfflineAnkiClient::rebuildDeckData()
{
    m_deckData.clear();
    m_visibleDeckIds.clear();
    m_visibleDeckNames.clear();

    for (const DeckNode &n : m_deckNodes) {
        // Hide anything beneath a collapsed ancestor.
        bool hidden = false;
        for (const QString &c : m_collapsed) {
            if (n.name != c && n.name.startsWith(c + QStringLiteral("::"))) {
                hidden = true;
                break;
            }
        }
        if (hidden) continue;

        QVariantMap deck;
        deck.insert(QStringLiteral("title"),       n.name.split(QStringLiteral("::")).last());
        deck.insert(QStringLiteral("visible"),     true);
        deck.insert(QStringLiteral("indent"),      n.level);
        deck.insert(QStringLiteral("hasChildren"), n.hasChildren);
        deck.insert(QStringLiteral("collapsed"),   m_collapsed.contains(n.name));
        deck.insert(QStringLiteral("newC"),        n.newC);
        deck.insert(QStringLiteral("learnC"),      n.learnC);
        deck.insert(QStringLiteral("dueC"),        n.reviewC);
        m_deckData.append(deck);
        m_visibleDeckIds.append(n.id);
        m_visibleDeckNames.append(n.name);
    }
    emit deckDataChanged();
}

void OfflineAnkiClient::toggleDeck(int index)
{
    if (index < 0 || index >= m_visibleDeckNames.size()) return;
    const QString name = m_visibleDeckNames.at(index);
    if (m_collapsed.contains(name)) m_collapsed.remove(name);
    else                            m_collapsed.insert(name);
    rebuildDeckData();
}

// --- studying ---------------------------------------------------------------

void OfflineAnkiClient::startStudy(int index)
{
    if (index < 0 || index >= m_visibleDeckIds.size()) return;

    m_currentDeckId = m_visibleDeckIds.at(index);
    m_currentDeckName = m_visibleDeckNames.at(index).split(QStringLiteral("::")).last();
    emit currentDeckNameChanged();

    m_cardsReviewed = 0;
    emit cardsReviewedChanged();

    showNextCard();
}

void OfflineAnkiClient::showNextCard()
{
    const QVariantMap r = call(ankicore_next_card(m_currentDeckId),
                               QStringLiteral("Fetching next card"));
    if (r.isEmpty()) {
        setCurrentState(QStringLiteral("ERROR"));
        return;
    }

    const QVariant cardValue = r.value(QStringLiteral("card"));
    if (!cardValue.isValid() || cardValue.isNull()) {
        m_currentCardId = 0;
        m_currentRemaining = 0;
        emit currentRemainingChanged();
        setCurrentState(QStringLiteral("DONE"));
        return;
    }

    const QVariantMap card = cardValue.toMap();
    m_currentCardId = card.value(QStringLiteral("id")).toLongLong();

    m_currentFront = card.value(QStringLiteral("question")).toString();
    emit currentFrontChanged();

    m_currentBack = card.value(QStringLiteral("answer")).toString();
    emit currentBackChanged();

    m_currentButtonLabels = card.value(QStringLiteral("buttons")).toStringList();
    emit currentButtonLabelsChanged();

    // Anki's own remaining counts, so the number matches the desktop rather
    // than a local tally.
    m_currentRemaining = r.value(QStringLiteral("new")).toInt()
                       + r.value(QStringLiteral("review")).toInt();
    emit currentRemainingChanged();

    m_cardTimer.start();
    setCurrentState(QStringLiteral("STUDY"));
}

void OfflineAnkiClient::answerCard(int button)
{
    if (button < 1 || button > 4) return;
    if (m_currentCardId == 0) return;

    const int taken = m_cardTimer.isValid()
                      ? int(qMin<qint64>(m_cardTimer.elapsed(), 600000)) : 0;

    // rslib writes the review straight into the collection: the scheduling
    // states and the revlog entry are Anki's own, not a queued approximation
    // to be reconciled later.
    const QVariantMap r = call(ankicore_answer_card(m_currentCardId, button, taken),
                               QStringLiteral("Answering card"));
    if (r.isEmpty()) {
        setCurrentState(QStringLiteral("ERROR"));
        return;
    }

    ++m_cardsReviewed;
    emit cardsReviewedChanged();

    showNextCard();
}

// --- navigation -------------------------------------------------------------

void OfflineAnkiClient::goHome()
{
    m_currentDeckId = 0;
    m_currentCardId = 0;
    setCurrentState(QStringLiteral("HOME"));
}

void OfflineAnkiClient::checkForNewCards()
{
    loadDecks();
}

void OfflineAnkiClient::login(const QString &email, const QString &password)
{
    Q_UNUSED(email)
    Q_UNUSED(password)
    // Retained only so the QML binding resolves; there is nothing to log into.
}
