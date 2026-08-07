#include "offlineclient.h"

#include <QDateTime>
#include <QDebug>
#include <QDir>
#include <QFile>
#include <QFileSystemWatcher>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QTimer>
#include <QVariantMap>

namespace {
constexpr int  QUEUE_VERSION = 1;
const char    *BATCH_FILE    = "anki-batch.json";
const char    *QUEUE_FILE    = "anki-queue.json";
}

OfflineAnkiClient::OfflineAnkiClient(QObject *parent)
    : QObject(parent)
{
    // Do NOT use QDir::homePath(): systemd services inherit no HOME, so it
    // resolves to "/" and the app hunts for /anki-batch.json while the batch
    // sits unread in /home/root. Fine over SSH, broken under the launcher.
    // On a reMarkable this is always root's home; the env var is an escape
    // hatch for testing.
    QString home = qEnvironmentVariable("RMANKI_HOME");
    if (home.isEmpty())
        home = QStringLiteral("/home/root");

    m_batchPath = home + QLatin1Char('/') + QLatin1String(BATCH_FILE);
    m_queuePath = home + QLatin1Char('/') + QLatin1String(QUEUE_FILE);

    // Watch for the PC pushing a new batch. The directory is watched as well
    // as the file: scp replaces the file, which can drop a file-only watch.
    m_watcher = new QFileSystemWatcher(this);
    m_watcher->addPath(home);
    if (QFile::exists(m_batchPath))
        m_watcher->addPath(m_batchPath);

    m_reloadDebounce = new QTimer(this);
    m_reloadDebounce->setSingleShot(true);
    m_reloadDebounce->setInterval(1200);      // let the copy finish landing
    connect(m_reloadDebounce, &QTimer::timeout, this, &OfflineAnkiClient::checkForNewCards);

    connect(m_watcher, &QFileSystemWatcher::fileChanged,
            this, &OfflineAnkiClient::onBatchPathChanged);
    connect(m_watcher, &QFileSystemWatcher::directoryChanged,
            this, &OfflineAnkiClient::onBatchPathChanged);

    // Populate deck counts and batchInfo, then sit on the home screen. The
    // launcher starts this app at boot, so the first thing the user sees must
    // be a choice between Anki and the stock notes UI -- not a forced app.
    loadDecks();
    setCurrentState(QStringLiteral("HOME"));
}

void OfflineAnkiClient::onBatchPathChanged()
{
    // Never yank the card out from under someone mid-review.
    if (m_currentState == QLatin1String("STUDY")) return;
    m_reloadDebounce->start();
}

void OfflineAnkiClient::checkForNewCards()
{
    // A replaced file loses its watch entry; re-add it.
    if (QFile::exists(m_batchPath) && !m_watcher->files().contains(m_batchPath))
        m_watcher->addPath(m_batchPath);

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
    m_batchExportedAt = static_cast<qint64>(root.value(QStringLiteral("exported_at")).toDouble());

    m_cards.clear();
    const QJsonArray arr = root.value(QStringLiteral("cards")).toArray();
    for (const QJsonValue &v : arr) {
        const QJsonObject o = v.toObject();
        OfflineCard c;
        // Card ids exceed 2^31, so they must be read as doubles and cast,
        // not toInt().
        c.cardId    = static_cast<qint64>(o.value(QStringLiteral("card_id")).toDouble());
        c.deck      = o.value(QStringLiteral("deck")).toString(m_batchDeckName);
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

QStringList OfflineAnkiClient::deckNames() const
{
    QSet<QString> all;
    for (const OfflineCard &c : m_cards) {
        if (m_answeredIds.contains(c.cardId)) continue;

        // Insert every ancestor, not just the card's own deck. Decks like
        // "Eng" and "French" hold no cards themselves -- everything lives in
        // subdecks -- so without this they never appeared as rows and there
        // was nothing to tap to collapse them.
        const QStringList parts = c.deck.split(QStringLiteral("::"));
        QString path;
        for (const QString &part : parts) {
            path = path.isEmpty() ? part : path + QStringLiteral("::") + part;
            all.insert(path);
        }
    }

    QStringList names = all.values();
    names.sort();
    return names;
}

int OfflineAnkiClient::pendingInDeck(const QString &deck) const
{
    // Counts subdecks too, so a parent row shows the total beneath it --
    // matching what tapping that row will actually study.
    int n = 0;
    for (const OfflineCard &c : m_cards) {
        if (m_answeredIds.contains(c.cardId)) continue;
        if (c.deck == deck || c.deck.startsWith(deck + QStringLiteral("::"))) ++n;
    }
    return n;
}

void OfflineAnkiClient::rebuildDeckData()
{
    m_deckData.clear();
    m_visibleDecks.clear();

    const QStringList names = deckNames();

    // Anki deck names are "Parent::Child"; indent by depth and let a parent
    // collapse its children, matching how the deck list behaves on desktop.
    for (const QString &name : names) {
        const QStringList parts = name.split(QStringLiteral("::"));
        const int depth = parts.size() - 1;

        bool hiddenByParent = false;
        for (const QString &collapsed : m_collapsedDecks) {
            if (name != collapsed && name.startsWith(collapsed + QStringLiteral("::"))) {
                hiddenByParent = true;
                break;
            }
        }
        if (hiddenByParent) continue;

        bool hasChildren = false;
        for (const QString &other : names) {
            if (other.startsWith(name + QStringLiteral("::"))) { hasChildren = true; break; }
        }

        QVariantMap deck;
        deck.insert(QStringLiteral("title"),       parts.last());
        deck.insert(QStringLiteral("visible"),     true);
        deck.insert(QStringLiteral("indent"),      depth);
        deck.insert(QStringLiteral("hasChildren"), hasChildren);
        deck.insert(QStringLiteral("collapsed"),   m_collapsedDecks.contains(name));
        // The PC applied deck limits when building the batch, so every
        // pending card is simply "due" from the tablet's point of view.
        deck.insert(QStringLiteral("newC"),   0);
        deck.insert(QStringLiteral("learnC"), 0);
        deck.insert(QStringLiteral("dueC"),   pendingInDeck(name));
        m_deckData.append(deck);
        m_visibleDecks << name;
    }
    emit deckDataChanged();
}

void OfflineAnkiClient::loadDecks()
{
    setCurrentState(QStringLiteral("LOADING"));
    setStatusMessage(QStringLiteral("Reading cards..."));

    // Returning to the deck list means no single deck is being studied.
    m_activeDeck.clear();

    if (!loadBatch()) return;      // loadBatch() already set the error state
    loadExistingQueue();

    // Clear any stale failure. Without this, one early error (say the batch
    // had not arrived yet at boot) stuck forever: the reload succeeded and
    // the state advanced, but the home screen kept reading errorMessage and
    // insisting there were no cards.
    if (!m_errorMessage.isEmpty()) {
        m_errorMessage.clear();
        emit errorMessageChanged();
    }

    // Start with every parent collapsed, so 57 decks open as a short list of
    // subjects rather than a wall of subdecks. Done once, so the user's own
    // expand/collapse choices survive a batch reload.
    if (!m_collapseInitialised) {
        m_collapseInitialised = true;
        const QStringList names = deckNames();
        for (const QString &name : names) {
            for (const QString &other : names) {
                if (other.startsWith(name + QStringLiteral("::"))) {
                    m_collapsedDecks.insert(name);
                    break;
                }
            }
        }
    }

    m_cardsReviewed = m_answeredIds.size();
    emit cardsReviewedChanged();

    m_currentTotal = m_cards.size();
    emit currentTotalChanged();

    m_currentRemaining = pendingCount();
    emit currentRemainingChanged();

    emit pendingAnswersChanged();

    QString when = QStringLiteral("unknown time");
    if (m_batchExportedAt > 0) {
        when = QDateTime::fromSecsSinceEpoch(m_batchExportedAt)
                   .toString(QStringLiteral("d MMM, HH:mm"));
    }
    m_batchInfo = QStringLiteral("%1 card(s) sent from your PC on %2")
                      .arg(m_cards.size()).arg(when);
    emit batchInfoChanged();

    rebuildDeckData();

    if (m_currentRemaining == 0) {
        setCurrentState(QStringLiteral("DONE"));
        return;
    }
    setCurrentState(QStringLiteral("DECKS"));
}

void OfflineAnkiClient::goHome()
{
    m_activeDeck.clear();
    setCurrentState(QStringLiteral("HOME"));
}

void OfflineAnkiClient::toggleDeck(int index)
{
    if (index < 0 || index >= m_visibleDecks.size()) return;
    const QString name = m_visibleDecks.at(index);
    if (m_collapsedDecks.contains(name)) m_collapsedDecks.remove(name);
    else                                 m_collapsedDecks.insert(name);
    rebuildDeckData();
}

// --- studying ---------------------------------------------------------------

void OfflineAnkiClient::startStudy(int index)
{
    if (index < 0 || index >= m_visibleDecks.size()) return;

    // Tapping a parent deck studies it and everything beneath it, as on desktop.
    m_activeDeck = m_visibleDecks.at(index);

    m_currentDeckName = m_activeDeck.split(QStringLiteral("::")).last();
    emit currentDeckNameChanged();

    m_currentTotal = pendingInDeck(m_activeDeck);
    emit currentTotalChanged();

    m_index = 0;
    showNextCard();
}

bool OfflineAnkiClient::inActiveDeck(const OfflineCard &c) const
{
    if (m_activeDeck.isEmpty()) return true;
    return c.deck == m_activeDeck ||
           c.deck.startsWith(m_activeDeck + QStringLiteral("::"));
}

void OfflineAnkiClient::showNextCard()
{
    // Skip anything already answered or outside the deck being studied, so a
    // restart resumes where we left off and decks stay separate.
    while (m_index < m_cards.size() &&
           (m_answeredIds.contains(m_cards[m_index].cardId) ||
            !inActiveDeck(m_cards[m_index])))
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

    m_currentRemaining = m_activeDeck.isEmpty() ? pendingCount()
                                                : pendingInDeck(m_activeDeck);
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
    emit pendingAnswersChanged();

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
