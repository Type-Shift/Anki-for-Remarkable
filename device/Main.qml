import QtQuick
import QtQuick.Layouts
import QtQuick.Window

Window {
    id: root
    width: Screen.width
    height: Screen.height
    visible: true
    color: "white"
    title: "Anki E-Ink"

    // The only QML-local state: whether the answer side is shown.
    // Everything else comes from the C++ "anki" context property.
    property bool isAnswerRevealed: false

    // Whether the AnkiWeb sign-in sheet is open. The overlay below was
    // built for the old online client and never shown; it already has the
    // fields and keyboard, so it is reused rather than duplicated.
    property bool syncLoginOpen: false

    // Whether the Wi-Fi panel is open. Needed because running this app
    // requires stopping xochitl, which removes reMarkable's own settings UI.
    property bool wifiOpen: false

    // Fonts - scaled for reMarkable high-DPI (1872x2404)
    property string defaultFont: "sans-serif"

    // The launcher uses reMarkable's own typeface where it exists. Resolved
    // at runtime against the installed families rather than hardcoded, so a
    // missing font degrades to the next choice instead of silently falling
    // back to something arbitrary. Maison Neue is the stock UI face; the
    // Noto families ship with the device as reading fonts.
    property string brandFont: {
        var prefs = ["EB Garamond", "Noto Serif", "Noto Sans UI",
                     "Noto Sans", "sans-serif"];
        var available = Qt.fontFamilies();
        for (var i = 0; i < prefs.length; i++) {
            if (available.indexOf(prefs[i]) !== -1)
                return prefs[i];
        }
        return "sans-serif";
    }
    property int headerFontSize: 48
    property int largeFontSize: 72
    property int normalFontSize: 52
    property int smallFontSize: 40

    function truncate(s, maxLen) {
        return s.length > maxLen ? s.substring(0, maxLen) + "..." : s
    }

    // ==========================================
    // UI Layout
    // ==========================================

    // 1. Header Area
    Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 140
        // The launcher carries its own status strip; the title bar and its
        // rule are clutter there.
        visible: anki.currentState !== "HOME"
        // Above the view Items (default z 0), below the overlays (100/200).
        // studyScreen fills the whole window and holds a full-screen
        // tap-to-reveal MouseArea; being declared later it stacked above the
        // header and swallowed every tap on the back arrow.
        z: 50

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 50
            anchors.verticalCenter: parent.verticalCenter
            spacing: 30

            Text {
                text: "\u2190"
                font.family: defaultFont
                font.pixelSize: headerFontSize
                font.bold: true
                color: "black"
                visible: anki.currentState === "STUDY" || anki.currentState === "DONE"
                         || anki.currentState === "DECKS"

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -30
                    // From the deck list there is nothing above but the
                    // launcher; from a card, step back to the deck list.
                    onClicked: anki.currentState === "DECKS"
                               ? anki.goHome()
                               : anki.loadDecks()
                }
            }

        }

        // Deliberately nothing else here. The title, the remaining counter,
        // the progress bar and the rule below them were all furniture; the
        // deck list and the card say what is going on without them.
    }

    // 2. Main Content Area
    Item {
        id: mainContent
        anchors.top: header.bottom
        anchors.bottom: footer.top
        anchors.left: parent.left
        anchors.right: parent.right

        // --- View: Loading ---
        Item {
            anchors.fill: parent
            visible: anki.currentState === "LOADING"

            Text {
                anchors.centerIn: parent
                text: anki.statusMessage
                font.family: defaultFont
                font.pixelSize: largeFontSize
                color: "black"
            }
        }

        // --- View: Error ---
        Item {
            anchors.fill: parent
            visible: anki.currentState === "ERROR"

            Column {
                anchors.centerIn: parent
                spacing: 50
                width: parent.width - 120

                Text {
                    text: "Something went wrong"
                    font.family: defaultFont
                    font.pixelSize: largeFontSize
                    font.bold: true
                    color: "black"
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: anki.errorMessage
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    color: "black"
                    wrapMode: Text.WordWrap
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                }

                Rectangle {
                    width: 400
                    height: 110
                    radius: 24
                    border.color: "black"
                    border.width: 3
                    color: "white"
                    anchors.horizontalCenter: parent.horizontalCenter

                    Text {
                        anchors.centerIn: parent
                        text: "Retry"
                        font.family: defaultFont
                        font.pixelSize: normalFontSize
                        color: "black"
                        font.bold: true
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: anki.loadDecks()
                    }
                }
            }
        }

        // --- View: Home (launcher) ---
        //
        // Stripped to the essentials: status at the top, a clock, and two
        // ways to go. Nothing else earns its place on a launcher.
        Item {
            id: homeView
            anchors.fill: parent
            visible: anki.currentState === "HOME"

            readonly property int sideMargin: 150

            // Handing the screen to xochitl quits Anki and needs a reboot to
            // undo, so it takes two taps. A single stray touch on e-ink must
            // not be able to throw you out of the app.
            property bool confirmExit: false

            Timer {
                id: confirmTimer
                interval: 5000
                // Timer is not an Item and has no `parent` property, so this
                // must reference the view by id.
                onTriggered: homeView.confirmExit = false
            }

            // --- Status strip ---------------------------------------------
            Item {
                id: homeStatus
                anchors.top: parent.top
                anchors.topMargin: 60
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: homeView.sideMargin
                anchors.rightMargin: homeView.sideMargin
                height: 70

                // Wi-Fi state as the familiar fan symbol, drawn rather than
                // set in text: no font on the device carries a Wi-Fi glyph.
                Canvas {
                    id: wifiIcon
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: 76
                    height: 62
                    antialiasing: true

                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.reset();
                        ctx.strokeStyle = "black";
                        ctx.fillStyle = "black";
                        ctx.lineCap = "round";

                        var cx = width / 2;
                        var cy = height - 10;

                        // Connected: all three arcs. Connecting: the inner one
                        // only. Off: all three, faint, with a slash.
                        var arcs = wifi.connected ? 3
                                                  : (wifi.status === "CONNECTING" ? 1 : 3);
                        ctx.globalAlpha = wifi.connected ? 1.0 : 0.35;
                        ctx.lineWidth = 7;

                        for (var i = 0; i < arcs; i++) {
                            var r = 16 + i * 15;
                            ctx.beginPath();
                            ctx.arc(cx, cy, r, Math.PI * 1.25, Math.PI * 1.75);
                            ctx.stroke();
                        }

                        // The base dot stays solid whenever the radio is up.
                        ctx.globalAlpha = (wifi.connected || wifi.status === "CONNECTING") ? 1.0 : 0.35;
                        ctx.beginPath();
                        ctx.arc(cx, cy, 5, 0, Math.PI * 2);
                        ctx.fill();

                        if (!wifi.connected && wifi.status !== "CONNECTING") {
                            ctx.globalAlpha = 1.0;
                            ctx.lineWidth = 6;
                            ctx.beginPath();
                            ctx.moveTo(10, 6);
                            ctx.lineTo(width - 10, height - 6);
                            ctx.stroke();
                        }
                    }

                    // Canvas does not repaint on its own when bindings change.
                    Connections {
                        target: wifi
                        function onStatusChanged() { wifiIcon.requestPaint() }
                    }

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -30      // comfortable tap target
                        onClicked: {
                            root.wifiOpen = true
                            wifi.scan()
                        }
                    }
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: device.charging ? (device.batteryLevel + " charging")
                                          : device.batteryLevel
                    font.family: brandFont
                    font.pixelSize: 40
                    color: "black"
                }
            }

            // --- Clock ----------------------------------------------------
            Column {
                id: homeClock
                anchors.centerIn: parent
                anchors.verticalCenterOffset: -220
                spacing: 10

                Text {
                    id: homeClockText
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.family: brandFont
                    font.pixelSize: 240
                    font.weight: Font.Light
                    color: "black"

                    Timer {
                        interval: 10000
                        running: true
                        repeat: true
                        triggeredOnStart: true
                        onTriggered: {
                            var d = new Date()
                            homeClockText.text = Qt.formatTime(d, "HH:mm")
                            homeDateText.text  = Qt.formatDate(d, "dddd d MMMM")
                        }
                    }
                }

                Text {
                    id: homeDateText
                    anchors.horizontalCenter: parent.horizontalCenter
                    font.family: brandFont
                    font.pixelSize: 48
                    font.weight: Font.Light
                    color: "#555555"
                }
            }

            // --- Choices --------------------------------------------------
            Column {
                anchors.top: homeClock.bottom
                anchors.topMargin: 220
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: homeView.sideMargin
                anchors.rightMargin: homeView.sideMargin
                spacing: 0

                Rectangle { width: parent.width; height: 2; color: "black" }

                Item {
                    width: parent.width
                    height: 220

                    Text {
                        anchors.centerIn: parent
                        text: "Anki"
                        font.family: brandFont
                        font.pixelSize: 84
                        color: "black"
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: anki.loadDecks()
                    }
                }

                Rectangle { width: parent.width; height: 1; color: "#BBBBBB" }

                // Sync. Shows what it is doing, since rslib's sync can take a
                // while on this radio and silence would read as a hang.
                Item {
                    width: parent.width
                    height: 220

                    Text {
                        anchors.centerIn: parent
                        text: {
                            if (sync.busy) return sync.status
                            if (!wifi.connected) return "Sync"
                            return sync.loggedIn ? "Sync" : "Sign in"
                        }
                        font.family: brandFont
                        font.pixelSize: 84
                        color: (wifi.connected || sync.busy) ? "black" : "#AAAAAA"
                    }

                    Text {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: {
                            if (sync.busy) return ""
                            if (!wifi.connected) return "no Wi-Fi"
                            if (sync.lastError !== "") return "failed"
                            return sync.status
                        }
                        font.family: brandFont
                        font.pixelSize: 40
                        font.weight: Font.Light
                        color: "#888888"
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: wifi.connected && !sync.busy
                        onClicked: {
                            if (sync.loggedIn) sync.sync()
                            else               root.syncLoginOpen = true
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: "#BBBBBB" }

                Item {
                    width: parent.width
                    height: 220

                    Text {
                        anchors.centerIn: parent
                        text: homeView.confirmExit ? "keep holding..." : "reMarkable"
                        font.family: brandFont
                        font.pixelSize: 84
                        color: "black"
                    }

                    // Press and hold, not tap. The device log showed
                    // exitToNotes() firing with nobody touching the tablet:
                    // stray digitiser events were hitting this row often
                    // enough to satisfy even a two-tap confirmation, dropping
                    // out of Anki and letting the tablet sleep. A sustained
                    // hold is something spurious touches do not produce.
                    MouseArea {
                        anchors.fill: parent
                        pressAndHoldInterval: 1500

                        onPressed: {
                            homeView.confirmExit = true
                            confirmTimer.stop()
                        }
                        onReleased: {
                            homeView.confirmExit = false
                        }
                        onCanceled: {
                            homeView.confirmExit = false
                        }
                        onPressAndHold: {
                            homeView.confirmExit = false
                            device.exitToNotes()
                        }
                    }
                }

                Rectangle { width: parent.width; height: 2; color: "black" }
            }
        }

        // --- View: Done ---
        Item {
            anchors.fill: parent
            visible: anki.currentState === "DONE"

            Column {
                anchors.centerIn: parent
                spacing: 50

                Text {
                    text: "Congratulations!"
                    font.family: defaultFont
                    font.pixelSize: largeFontSize
                    font.bold: true
                    color: "black"
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "You've finished every card sent to this device."
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    color: "black"
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                Text {
                    text: "Reviewed " + anki.cardsReviewed + " card(s)."
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    color: "black"
                    anchors.horizontalCenter: parent.horizontalCenter
                    visible: anki.cardsReviewed > 0
                }

                // The crucial bit that was missing: say what to do next.
                // Finishing a batch used to loop straight back to this screen
                // with no explanation and no way forward.
                Rectangle {
                    width: 1100
                    height: 220
                    radius: 20
                    color: "#F2F2F2"
                    border.color: "black"
                    border.width: 3
                    anchors.horizontalCenter: parent.horizontalCenter

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - 80
                        spacing: 14

                        Text {
                            text: anki.pendingAnswers > 0
                                  ? (anki.pendingAnswers + " answer(s) saved, waiting for your PC")
                                  : "All answers have been collected by your PC"
                            font.family: defaultFont
                            font.pixelSize: smallFontSize
                            font.bold: true
                            color: "black"
                            wrapMode: Text.WordWrap
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Text {
                            text: "To get more cards, connect to Wi-Fi and run sync.ps1 on your PC. New cards appear here automatically."
                            font.family: defaultFont
                            font.pixelSize: smallFontSize
                            color: "#444444"
                            wrapMode: Text.WordWrap
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                        }

                        Text {
                            text: anki.batchInfo
                            font.family: defaultFont
                            font.pixelSize: smallFontSize
                            color: "#777777"
                            wrapMode: Text.WordWrap
                            width: parent.width
                            horizontalAlignment: Text.AlignHCenter
                        }
                    }
                }

                Row {
                    spacing: 40
                    anchors.horizontalCenter: parent.horizontalCenter

                    Rectangle {
                        width: 520
                        height: 110
                        radius: 24
                        border.color: "black"
                        border.width: 3
                        color: "white"

                        Text {
                            anchors.centerIn: parent
                            text: "Check for new cards"
                            font.family: defaultFont
                            font.pixelSize: normalFontSize
                            color: "black"
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: anki.checkForNewCards()
                        }
                    }

                    Rectangle {
                        width: 300
                        height: 110
                        radius: 24
                        border.color: "black"
                        border.width: 3
                        color: "white"

                        Text {
                            anchors.centerIn: parent
                            text: "Wi-Fi"
                            font.family: defaultFont
                            font.pixelSize: normalFontSize
                            color: "black"
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                root.wifiOpen = true
                                wifi.scan()
                            }
                        }
                    }
                }
            }
        }

        // --- View: Deck Explorer ---
        Item {
            anchors.fill: parent
            visible: anki.currentState === "DECKS"

            Item {
                id: listHeader
                width: parent.width
                height: 110
                anchors.top: parent.top

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 60
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Deck"
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    font.bold: true
                    color: "black"
                }

                Row {
                    anchors.right: parent.right
                    anchors.rightMargin: 60
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 40
                    width: 550

                    Text { width: 150; text: "New";   font.bold: true; font.pixelSize: normalFontSize; horizontalAlignment: Text.AlignHCenter; color: "black" }
                    Text { width: 150; text: "Learn"; font.bold: true; font.pixelSize: normalFontSize; horizontalAlignment: Text.AlignHCenter; color: "black" }
                    Text { width: 150; text: "Due";   font.bold: true; font.pixelSize: normalFontSize; horizontalAlignment: Text.AlignHCenter; color: "black" }
                }

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width - 80
                    anchors.horizontalCenter: parent.horizontalCenter
                    height: 2
                    color: "black"
                    opacity: 0.2
                }
            }

            Flickable {
                anchors.top: listHeader.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                contentHeight: deckColumn.height
                clip: true

                // E-ink cannot repaint fast enough for kinetic scrolling:
                // momentum and rubber-band overshoot smear badly. Content
                // tracks the finger and stops dead when it lifts.
                maximumFlickVelocity: 0
                flickDeceleration: 100000
                boundsBehavior: Flickable.StopAtBounds
                pixelAligned: true

                Column {
                    id: deckColumn
                    width: parent.width
                    anchors.topMargin: 20
                    spacing: 10

                    Repeater {
                        model: anki.deckData

                        delegate: Item {
                            width: parent.width
                            height: modelData.visible ? 110 : 0
                            visible: modelData.visible
                            clip: true

                            // Full-row tap -> start studying this deck
                            MouseArea {
                                anchors.fill: parent
                                onClicked: anki.startStudy(index)
                            }

                            Row {
                                anchors.left: parent.left
                                anchors.leftMargin: 60 + (modelData.indent * 60)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 10

                                // Chevron toggle for parent decks
                                Item {
                                    width: modelData.hasChildren ? 55 : 0
                                    height: 55
                                    visible: modelData.hasChildren
                                    anchors.verticalCenter: parent.verticalCenter

                                    Text {
                                        anchors.centerIn: parent
                                        text: modelData.collapsed ? "\u25B6" : "\u25BC"
                                        font.pixelSize: 36
                                        color: "black"
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -20
                                        onClicked: anki.toggleDeck(index)
                                    }
                                }

                                Text {
                                    text: truncate(modelData.title, 30)
                                    font.family: defaultFont
                                    font.pixelSize: normalFontSize
                                    color: "black"
                                    font.bold: modelData.indent === 0
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Row {
                                anchors.right: parent.right
                                anchors.rightMargin: 60
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 40
                                width: 550

                                Text { width: 150; text: modelData.newC;   font.pixelSize: normalFontSize; horizontalAlignment: Text.AlignHCenter; color: "black" }
                                Text { width: 150; text: modelData.learnC; font.pixelSize: normalFontSize; horizontalAlignment: Text.AlignHCenter; color: "black" }
                                Text { width: 150; text: modelData.dueC;   font.pixelSize: normalFontSize; horizontalAlignment: Text.AlignHCenter; color: "black" }
                            }

                            Rectangle {
                                anchors.bottom: parent.bottom
                                width: parent.width - 80
                                anchors.horizontalCenter: parent.horizontalCenter
                                height: 1
                                color: "black"
                                opacity: 0.1
                            }
                        }
                    }
                }
            }
        }

        // --- View: Card Study ---
        //
        // The card scrolls. Previously it was a fixed Rectangle sized to its
        // contents, so a long card simply ran off the bottom of the screen
        // with no way to reach the rest of it. The rating buttons live at the
        // END of the scrollable content rather than floating over the card,
        // so answering never hides what you are reading.
        Item {
            id: studyScreen
            anchors.fill: parent
            visible: anki.currentState === "STUDY"

            Flickable {
                id: cardScroll
                anchors.fill: parent
                anchors.leftMargin: 60
                anchors.rightMargin: 60
                anchors.topMargin: 40
                anchors.bottomMargin: 20
                contentHeight: cardColumn.height
                clip: true

                // Killing flick entirely made scrolling track the finger 1:1,
                // which on e-ink reads as sluggish and barely moves the page.
                // A flick now covers real distance but decelerates hard, so
                // there is one jump and one repaint rather than a long smear.
                maximumFlickVelocity: 6000
                flickDeceleration: 9000
                boundsBehavior: Flickable.StopAtBounds
                pixelAligned: true

                Column {
                    id: cardColumn
                    width: cardScroll.width
                    spacing: 50

                    Text {
                        text: truncate(anki.currentDeckName, 40)
                        font.family: defaultFont
                        font.pixelSize: 36
                        color: "#666666"
                    }

                    Text {
                        text: anki.currentFront
                        font.family: defaultFont
                        font.pixelSize: largeFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    // Explicit button rather than a full-screen tap target:
                    // a stray touch anywhere used to reveal the answer.
                    Rectangle {
                        width: parent.width
                        height: 120
                        radius: 20
                        border.color: "black"
                        border.width: 3
                        color: "white"
                        visible: !isAnswerRevealed

                        Text {
                            anchors.centerIn: parent
                            text: "Show answer"
                            font.family: defaultFont
                            font.pixelSize: normalFontSize
                            color: "black"
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: isAnswerRevealed = true
                        }
                    }

                    Rectangle {
                        width: parent.width
                        height: 2
                        color: "black"
                        visible: isAnswerRevealed
                    }

                    Text {
                        text: anki.currentBack
                        font.family: defaultFont
                        font.pixelSize: largeFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                        width: parent.width
                        visible: isAnswerRevealed
                    }

                    // Rating buttons, at the end of the card content.
                    Grid {
                        width: parent.width
                        visible: isAnswerRevealed
                        columns: 4
                        columnSpacing: 30
                        rowSpacing: 30

                        Repeater {
                            model: {
                                var labels = anki.currentButtonLabels;
                                var names  = ["Again", "Hard", "Good", "Easy"];
                                var items  = [];
                                for (var i = 0; i < labels.length && i < 4; i++) {
                                    items.push({
                                        label:  names[i] || ("Btn " + (i + 1)),
                                        time:   labels[i],
                                        button: i + 1
                                    });
                                }
                                return items;
                            }

                            delegate: Rectangle {
                                width: (cardColumn.width - 90) / 4
                                height: 150
                                radius: 20
                                border.color: "black"
                                border.width: 3
                                color: "white"

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 8

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.label
                                        font.family: defaultFont
                                        font.pixelSize: normalFontSize
                                        font.bold: true
                                        color: "black"
                                    }

                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: modelData.time
                                        font.family: defaultFont
                                        font.pixelSize: smallFontSize
                                        color: "#666666"
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: anki.answerCard(modelData.button)
                                }
                            }
                        }
                    }

                    // Breathing room so the last row is never flush with the
                    // bottom edge when scrolled fully down.
                    Item { width: 1; height: 60 }
                }
            }
        }
    }

    // Reset when a new card is shown. The scroll position must reset too:
    // otherwise the next card opens already scrolled to wherever the last one
    // was left, which looks like a blank or half-missing card.
    Connections {
        target: anki
        function onCurrentFrontChanged() {
            isAnswerRevealed = false
            cardScroll.contentY = 0
        }
    }

    // 3. Footer Area
    Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        // Gone entirely. The clock, battery, Wi-Fi state and Home link all
        // live on the launcher, which is one tap away; repeating them under
        // every card was noise. Height stays zero so nothing reserves space.
        height: 0
        visible: false

        Item {
            id: statusBar
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: anki.currentState === "HOME" ? 0 : 80

            Rectangle {
                anchors.top: parent.top
                width: parent.width
                height: 3
                color: "black"
            }

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 50
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                font.family: defaultFont
                font.pixelSize: smallFontSize
                color: "black"
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: 50
                anchors.verticalCenter: parent.verticalCenter
                spacing: 30

                Text {
                    text: "Home"
                    font.family: defaultFont
                    font.pixelSize: smallFontSize
                    font.underline: true
                    color: "black"
                    anchors.verticalCenter: parent.verticalCenter
                    visible: anki.currentState !== "HOME"

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -30
                        onClicked: anki.goHome()
                    }
                }

                Text {
                    text: device.charging ? (device.batteryLevel + " +") : device.batteryLevel
                    font.family: defaultFont
                    font.pixelSize: smallFontSize
                    color: "black"
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    id: clockText
                    font.family: defaultFont
                    font.pixelSize: smallFontSize
                    color: "black"
                    anchors.verticalCenter: parent.verticalCenter

                    Timer {
                        interval: 15000
                        running: true
                        repeat: true
                        triggeredOnStart: true
                        onTriggered: clockText.text = new Date().toLocaleTimeString(Qt.locale(), "HH:mm")
                    }
                }

                // Wi-Fi status doubles as the button that opens the panel.
                Rectangle {
                    width: 20
                    height: 20
                    radius: 10
                    color: wifi.connected ? "green"
                                          : (wifi.status === "CONNECTING" ? "orange" : "red")
                    anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                    id: wifiStatusText
                    text: {
                        if (wifi.connected) return truncate(wifi.currentSsid, 18);
                        if (wifi.status === "CONNECTING") return "Connecting...";
                        return "Wi-Fi off";
                    }
                    font.family: defaultFont
                    font.pixelSize: smallFontSize
                    font.underline: true
                    color: "black"
                    anchors.verticalCenter: parent.verticalCenter

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -30
                        onClicked: {
                            root.wifiOpen = true
                            wifi.scan()
                        }
                    }
                }
            }
        }
    }

    // ==========================================
    // LOGIN Overlay (covers entire screen)
    // ==========================================
    Item {
        id: loginOverlay
        anchors.fill: parent
        visible: root.syncLoginOpen
        z: 100 // above everything

        // QML-local login state
        property int focusedField: 0   // 0 = email, 1 = password
        property string emailInput: ""
        property string passwordInput: ""
        property bool shifted: false
        property bool symbols: false

        function typeChar(ch) {
            if (focusedField === 0)
                emailInput += (shifted && !symbols) ? ch.toUpperCase() : ch
            else
                passwordInput += (shifted && !symbols) ? ch.toUpperCase() : ch
            if (shifted) shifted = false
        }

        function backspace() {
            if (focusedField === 0 && emailInput.length > 0)
                emailInput = emailInput.substring(0, emailInput.length - 1)
            else if (focusedField === 1 && passwordInput.length > 0)
                passwordInput = passwordInput.substring(0, passwordInput.length - 1)
        }

        function submitLogin() {
            if (emailInput.length > 0 && passwordInput.length > 0) {
                sync.login(emailInput, passwordInput)
                // Do not keep the password in QML state once it has been
                // handed over; rslib exchanges it for a key immediately.
                passwordInput = ""
                root.syncLoginOpen = false
            }
        }

        // White background
        Rectangle {
            anchors.fill: parent
            color: "white"
        }

        // Without this the sheet could only be left by signing in.
        Text {
            anchors.top: parent.top
            anchors.right: parent.right
            anchors.margins: 60
            text: "Cancel"
            font.family: brandFont
            font.pixelSize: 48
            color: "black"
            z: 10

            MouseArea {
                anchors.fill: parent
                anchors.margins: -40
                onClicked: {
                    loginOverlay.passwordInput = ""
                    root.syncLoginOpen = false
                }
            }
        }

        // ---- Top section: title + input fields ----
        Column {
            id: loginFields
            anchors.top: parent.top
            anchors.topMargin: 100
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 160
            spacing: 30

            Text {
                text: sync.busy ? sync.status : "Sign in to AnkiWeb"
                font.family: defaultFont
                font.pixelSize: largeFontSize
                font.bold: true
                color: "black"
                anchors.horizontalCenter: parent.horizontalCenter
            }

            // Error message
            Text {
                text: anki.errorMessage
                font.family: defaultFont
                font.pixelSize: smallFontSize
                color: "#D32F2F"
                wrapMode: Text.WordWrap
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                visible: anki.errorMessage !== ""
            }

            Item { width: 1; height: 10 }

            // Email label
            Text {
                text: "Email"
                font.family: defaultFont
                font.pixelSize: smallFontSize
                color: "black"
            }

            // Email field
            Rectangle {
                width: parent.width
                height: 100
                radius: 12
                border.color: loginOverlay.focusedField === 0 ? "black" : "#999999"
                border.width: loginOverlay.focusedField === 0 ? 4 : 2
                color: "white"

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 48
                    text: loginOverlay.emailInput
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    color: "black"
                    elide: Text.ElideRight
                    visible: loginOverlay.emailInput.length > 0
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    text: "your@email.com"
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    color: "#AAAAAA"
                    visible: loginOverlay.emailInput.length === 0
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: loginOverlay.focusedField = 0
                }
            }

            Item { width: 1; height: 10 }

            // Password label
            Text {
                text: "Password"
                font.family: defaultFont
                font.pixelSize: smallFontSize
                color: "black"
            }

            // Password field
            Rectangle {
                width: parent.width
                height: 100
                radius: 12
                border.color: loginOverlay.focusedField === 1 ? "black" : "#999999"
                border.width: loginOverlay.focusedField === 1 ? 4 : 2
                color: "white"

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 48
                    text: "\u2022".repeat(loginOverlay.passwordInput.length)
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    color: "black"
                    elide: Text.ElideRight
                    visible: loginOverlay.passwordInput.length > 0
                }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 24
                    anchors.verticalCenter: parent.verticalCenter
                    text: "password"
                    font.family: defaultFont
                    font.pixelSize: normalFontSize
                    color: "#AAAAAA"
                    visible: loginOverlay.passwordInput.length === 0
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: loginOverlay.focusedField = 1
                }
            }
        }

        // ---- Bottom section: on-screen QWERTY keyboard ----
        // All rows total 1692px (10 keys * 162 + 9 gaps * 8) for edge alignment
        Column {
            id: keyboardLayout
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 40
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: 12

            property int keyW: 130
            property int keyH: 95
            property int gap: 8

            property var lettersRow1: ["q","w","e","r","t","y","u","i","o","p"]
            property var lettersRow2: ["a","s","d","f","g","h","j","k","l"]
            property var lettersRow3: ["z","x","c","v","b","n","m"]
            property var symbolsRow1: ["1","2","3","4","5","6","7","8","9","0"]
            property var symbolsRow2: ["@","#","$","&","*","(",")","-","="]
            property var symbolsRow3: ["+","!","?","/","\\",":",";","'","\""]

            property var row1: loginOverlay.symbols ? symbolsRow1 : lettersRow1
            property var row2: loginOverlay.symbols ? symbolsRow2 : lettersRow2
            property var row3: loginOverlay.symbols ? symbolsRow3 : lettersRow3

            // Row 1: 10 keys (defines total width: 1692px)
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: keyboardLayout.gap

                Repeater {
                    model: keyboardLayout.row1
                    delegate: Rectangle {
                        width: keyboardLayout.keyW
                        height: keyboardLayout.keyH
                        radius: 10
                        border.color: "black"
                        border.width: 2
                        color: r1ma.pressed ? "#CCCCCC" : "white"

                        Text {
                            anchors.centerIn: parent
                            text: (loginOverlay.shifted && !loginOverlay.symbols) ? modelData.toUpperCase() : modelData
                            font.family: defaultFont
                            font.pixelSize: 48
                            color: "black"
                        }

                        MouseArea {
                            id: r1ma
                            anchors.fill: parent
                            onClicked: loginOverlay.typeChar(modelData)
                        }
                    }
                }
            }

            // Row 2: 9 keys (centered, classic QWERTY offset)
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: keyboardLayout.gap

                Repeater {
                    model: keyboardLayout.row2
                    delegate: Rectangle {
                        width: keyboardLayout.keyW
                        height: keyboardLayout.keyH
                        radius: 10
                        border.color: "black"
                        border.width: 2
                        color: r2ma.pressed ? "#CCCCCC" : "white"

                        Text {
                            anchors.centerIn: parent
                            text: (loginOverlay.shifted && !loginOverlay.symbols) ? modelData.toUpperCase() : modelData
                            font.family: defaultFont
                            font.pixelSize: 48
                            color: "black"
                        }

                        MouseArea {
                            id: r2ma
                            anchors.fill: parent
                            onClicked: loginOverlay.typeChar(modelData)
                        }
                    }
                }
            }

            // Row 3: SHIFT + 7 keys + DEL = 1372px total
            // SHIFT/DEL width: (1372 - 7*130 - 8*8) / 2 = 199
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: keyboardLayout.gap

                // Shift key (letters mode)
                Rectangle {
                    width: 199
                    height: keyboardLayout.keyH
                    radius: 10
                    border.color: "black"
                    border.width: 2
                    color: shiftMa.pressed ? "#AAAAAA" : (loginOverlay.shifted ? "#CCCCCC" : "white")
                    visible: !loginOverlay.symbols

                    Text {
                        anchors.centerIn: parent
                        text: "SHIFT"
                        font.family: defaultFont
                        font.pixelSize: 40
                        font.bold: true
                        color: "black"
                    }

                    MouseArea {
                        id: shiftMa
                        anchors.fill: parent
                        onClicked: loginOverlay.shifted = !loginOverlay.shifted
                    }
                }

                // Spacer (symbols mode -- replaces shift)
                Item {
                    width: 199
                    height: keyboardLayout.keyH
                    visible: loginOverlay.symbols
                }

                Repeater {
                    model: keyboardLayout.row3
                    delegate: Rectangle {
                        width: keyboardLayout.keyW
                        height: keyboardLayout.keyH
                        radius: 10
                        border.color: "black"
                        border.width: 2
                        color: r3ma.pressed ? "#CCCCCC" : "white"

                        Text {
                            anchors.centerIn: parent
                            text: (loginOverlay.shifted && !loginOverlay.symbols) ? modelData.toUpperCase() : modelData
                            font.family: defaultFont
                            font.pixelSize: 48
                            color: "black"
                        }

                        MouseArea {
                            id: r3ma
                            anchors.fill: parent
                            onClicked: loginOverlay.typeChar(modelData)
                        }
                    }
                }

                // Backspace key
                Rectangle {
                    width: 199
                    height: keyboardLayout.keyH
                    radius: 10
                    border.color: "black"
                    border.width: 2
                    color: delMa.pressed ? "#CCCCCC" : "white"

                    Text {
                        anchors.centerIn: parent
                        text: "DEL"
                        font.family: defaultFont
                        font.pixelSize: 40
                        font.bold: true
                        color: "black"
                    }

                    MouseArea {
                        id: delMa
                        anchors.fill: parent
                        onClicked: loginOverlay.backspace()
                    }
                }
            }

            // Row 4: 123 + @ + SPACE + . + Sign In = 1372px total
            // Space width: 1372 - 160 - 110 - 110 - 260 - 4*8 = 700
            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: keyboardLayout.gap

                // Symbol toggle
                Rectangle {
                    width: 160
                    height: keyboardLayout.keyH
                    radius: 10
                    border.color: "black"
                    border.width: 2
                    color: symMa.pressed ? "#AAAAAA" : (loginOverlay.symbols ? "#CCCCCC" : "white")

                    Text {
                        anchors.centerIn: parent
                        text: loginOverlay.symbols ? "ABC" : "123"
                        font.family: defaultFont
                        font.pixelSize: 44
                        font.bold: true
                        color: "black"
                    }

                    MouseArea {
                        id: symMa
                        anchors.fill: parent
                        onClicked: {
                            loginOverlay.symbols = !loginOverlay.symbols
                            loginOverlay.shifted = false
                        }
                    }
                }

                // @ key
                Rectangle {
                    width: 110
                    height: keyboardLayout.keyH
                    radius: 10
                    border.color: "black"
                    border.width: 2
                    color: atMa.pressed ? "#CCCCCC" : "white"

                    Text {
                        anchors.centerIn: parent
                        text: "@"
                        font.family: defaultFont
                        font.pixelSize: 48
                        color: "black"
                    }

                    MouseArea {
                        id: atMa
                        anchors.fill: parent
                        onClicked: loginOverlay.typeChar("@")
                    }
                }

                // Space bar
                Rectangle {
                    width: 700
                    height: keyboardLayout.keyH
                    radius: 10
                    border.color: "black"
                    border.width: 2
                    color: spaceMa.pressed ? "#CCCCCC" : "white"

                    Text {
                        anchors.centerIn: parent
                        text: "space"
                        font.family: defaultFont
                        font.pixelSize: 40
                        color: "#999999"
                    }

                    MouseArea {
                        id: spaceMa
                        anchors.fill: parent
                        onClicked: loginOverlay.typeChar(" ")
                    }
                }

                // . key
                Rectangle {
                    width: 110
                    height: keyboardLayout.keyH
                    radius: 10
                    border.color: "black"
                    border.width: 2
                    color: dotMa.pressed ? "#CCCCCC" : "white"

                    Text {
                        anchors.centerIn: parent
                        text: "."
                        font.family: defaultFont
                        font.pixelSize: 48
                        color: "black"
                    }

                    MouseArea {
                        id: dotMa
                        anchors.fill: parent
                        onClicked: loginOverlay.typeChar(".")
                    }
                }

                // Sign In button
                Rectangle {
                    property bool ready: loginOverlay.emailInput.length > 0 && loginOverlay.passwordInput.length > 0
                    width: 260
                    height: keyboardLayout.keyH
                    radius: 10
                    border.color: ready ? "black" : "#999999"
                    border.width: 3
                    color: submitMa.pressed ? "#444444" : (ready ? "black" : "white")

                    Text {
                        anchors.centerIn: parent
                        text: "Sign In"
                        font.family: defaultFont
                        font.pixelSize: 44
                        font.bold: true
                        color: parent.ready ? "white" : "#999999"
                    }

                    MouseArea {
                        id: submitMa
                        anchors.fill: parent
                        onClicked: loginOverlay.submitLogin()
                    }
                }
            }
        }
    }

    // ==========================================
    // Wi-Fi Overlay
    // ==========================================
    //
    // Same idiom as the launcher: hairline rules instead of boxes, wide
    // margins, EB Garamond, no filled shapes. E-ink flatters thin black
    // line work and ghosts on large solid fills.
    Item {
        id: wifiOverlay
        anchors.fill: parent
        visible: root.wifiOpen
        z: 200

        readonly property int sideMargin: 150

        property string selectedSsid: ""
        property bool   selectedSecured: false
        property bool   selectedSaved: false
        property string passwordInput: ""
        property bool   shifted: false
        property bool   symbols: false

        function selectNetwork(n) {
            selectedSsid    = n.ssid
            selectedSecured = n.secured
            selectedSaved   = n.saved
            passwordInput   = ""
        }

        function typeChar(ch) {
            passwordInput += shifted ? ch.toUpperCase() : ch
            if (shifted) shifted = false
        }

        function backspace() {
            if (passwordInput.length > 0)
                passwordInput = passwordInput.substring(0, passwordInput.length - 1)
        }

        function join() {
            if (selectedSsid === "") return
            // A saved network already has credentials stored; don't force the
            // user to retype a password they have entered before.
            if (selectedSaved && passwordInput === "")
                wifi.connectToSaved(selectedSsid)
            else
                wifi.connectToNetwork(selectedSsid, passwordInput)
            passwordInput = ""
        }

        Rectangle { anchors.fill: parent; color: "white" }

        // --- Header ---------------------------------------------------
        Item {
            id: wifiHeader
            anchors.top: parent.top
            anchors.topMargin: 60
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: wifiOverlay.sideMargin
            anchors.rightMargin: wifiOverlay.sideMargin
            height: 130

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Wi-Fi"
                font.family: brandFont
                font.pixelSize: 96
                font.weight: Font.Light
                color: "black"
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Done"
                font.family: brandFont
                font.pixelSize: 52
                color: "black"

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -40
                    onClicked: root.wifiOpen = false
                }
            }
        }

        // --- Status + actions -----------------------------------------
        Column {
            id: wifiStatusBlock
            anchors.top: wifiHeader.bottom
            anchors.topMargin: 20
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: wifiOverlay.sideMargin
            anchors.rightMargin: wifiOverlay.sideMargin
            spacing: 0

            Text {
                text: wifi.connected ? wifi.currentSsid
                                     : (wifi.status === "CONNECTING" ? "Connecting"
                                                                     : "Not connected")
                font.family: brandFont
                font.pixelSize: 48
                font.weight: Font.Light
                color: "#555555"
                bottomPadding: 6
            }

            Text {
                text: wifi.ipAddress === "" ? " " : wifi.ipAddress
                font.family: brandFont
                font.pixelSize: 36
                font.weight: Font.Light
                color: "#888888"
                bottomPadding: 20
            }

            Text {
                text: wifi.wifiError
                visible: wifi.wifiError !== ""
                font.family: brandFont
                font.pixelSize: 36
                color: "black"
                wrapMode: Text.WordWrap
                width: parent.width
                bottomPadding: 20
            }

            Rectangle { width: parent.width; height: 2; color: "black" }

            Item {
                width: parent.width
                height: 130

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: wifi.connected ? "Turn off" : "Turn on"
                    font.family: brandFont
                    font.pixelSize: 52
                    color: "black"
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: wifi.scanning ? "scanning" : "scan"
                    font.family: brandFont
                    font.pixelSize: 44
                    color: "#777777"

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -40
                        onClicked: wifi.scan()
                    }
                }

                MouseArea {
                    anchors.left: parent.left
                    anchors.top: parent.top
                    anchors.bottom: parent.bottom
                    width: parent.width / 2
                    onClicked: wifi.connected ? wifi.disconnectWifi() : wifi.reconnectWifi()
                }
            }

            Rectangle { width: parent.width; height: 2; color: "black" }
        }

        // --- Network list ---------------------------------------------
        Flickable {
            id: netList
            anchors.top: wifiStatusBlock.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: wifiOverlay.sideMargin
            anchors.rightMargin: wifiOverlay.sideMargin
            anchors.bottom: wifiKeyboard.visible ? wifiKeyboard.top : joinRow.top
            anchors.bottomMargin: 20
            contentHeight: netColumn.height
            clip: true

            maximumFlickVelocity: 6000
            flickDeceleration: 9000
            boundsBehavior: Flickable.StopAtBounds
            pixelAligned: true

            Column {
                id: netColumn
                width: parent.width
                spacing: 0

                Text {
                    text: "No networks found. Tap scan."
                    visible: wifi.networks.length === 0
                    font.family: brandFont
                    font.pixelSize: 40
                    font.weight: Font.Light
                    color: "#888888"
                    topPadding: 30
                }

                Repeater {
                    model: wifi.networks

                    delegate: Item {
                        width: netColumn.width
                        height: 130

                        Text {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            text: (modelData.ssid === wifiOverlay.selectedSsid ? "- " : "")
                                  + modelData.ssid
                            font.family: brandFont
                            font.pixelSize: 52
                            font.weight: modelData.current ? Font.Normal : Font.Light
                            color: "black"
                            elide: Text.ElideRight
                            width: parent.width - 320
                        }

                        Text {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                                if (modelData.current) return "connected"
                                var bits = []
                                if (modelData.saved) bits.push("saved")
                                if (!modelData.secured) bits.push("open")
                                bits.push(modelData.bars + "/4")
                                return bits.join("  ")
                            }
                            font.family: brandFont
                            font.pixelSize: 36
                            font.weight: Font.Light
                            color: "#888888"
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 1
                            color: "#CCCCCC"
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: wifiOverlay.selectNetwork(modelData)
                        }
                    }
                }
            }
        }

        // --- Join / forget row ----------------------------------------
        Item {
            id: joinRow
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 60
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: wifiOverlay.sideMargin
            anchors.rightMargin: wifiOverlay.sideMargin
            height: wifiOverlay.selectedSsid === "" ? 0 : 130
            visible: wifiOverlay.selectedSsid !== "" && !wifiKeyboard.visible

            Rectangle {
                anchors.top: parent.top
                width: parent.width
                height: 2
                color: "black"
            }

            Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Connect"
                font.family: brandFont
                font.pixelSize: 52
                color: "black"

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -40
                    onClicked: wifiOverlay.join()
                }
            }

            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Forget"
                visible: wifiOverlay.selectedSaved
                font.family: brandFont
                font.pixelSize: 44
                color: "#777777"

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -40
                    onClicked: {
                        wifi.forgetNetwork(wifiOverlay.selectedSsid)
                        wifiOverlay.selectedSsid = ""
                    }
                }
            }
        }

        // --- Password entry + keyboard --------------------------------
        Column {
            id: wifiKeyboard
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 30
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - (wifiOverlay.sideMargin * 2)
            spacing: 14
            // Only needed when joining a secured network we have no password for.
            visible: wifiOverlay.selectedSsid !== "" &&
                     wifiOverlay.selectedSecured &&
                     !(wifiOverlay.selectedSaved && wifiOverlay.passwordInput === "")

            Rectangle { width: parent.width; height: 2; color: "black" }

            Item {
                width: parent.width
                height: 120

                Text {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: wifiOverlay.passwordInput.length > 0
                          ? wifiOverlay.passwordInput
                          : ("Password for " + wifiOverlay.selectedSsid)
                    font.family: brandFont
                    font.pixelSize: 44
                    font.weight: Font.Light
                    color: wifiOverlay.passwordInput.length > 0 ? "black" : "#999999"
                    elide: Text.ElideRight
                    width: parent.width - 260
                }

                Text {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Connect"
                    font.family: brandFont
                    font.pixelSize: 48
                    color: "black"

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -40
                        onClicked: wifiOverlay.join()
                    }
                }
            }

            Repeater {
                model: wifiOverlay.symbols
                       ? ["1234567890", "!@#$%^&*()", "-_=+[]{};:", "'\",.<>/?\\|"]
                       : ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

                delegate: Row {
                    anchors.horizontalCenter: parent.horizontalCenter
                    spacing: 10

                    Repeater {
                        model: modelData.split("")

                        delegate: Rectangle {
                            width: 145; height: 95; radius: 10
                            border.color: "black"; border.width: 2; color: "white"
                            Text {
                                anchors.centerIn: parent
                                text: wifiOverlay.shifted && !wifiOverlay.symbols
                                      ? modelData.toUpperCase() : modelData
                                font.family: brandFont
                                font.pixelSize: 44
                                color: "black"
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: wifiOverlay.typeChar(modelData)
                            }
                        }
                    }
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 10

                Rectangle {
                    width: 210; height: 95; radius: 10
                    border.color: "black"; border.width: 2
                    color: wifiOverlay.shifted ? "#DDDDDD" : "white"
                    Text {
                        anchors.centerIn: parent; text: "shift"
                        font.family: brandFont; font.pixelSize: 40; color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: wifiOverlay.shifted = !wifiOverlay.shifted
                    }
                }

                Rectangle {
                    width: 210; height: 95; radius: 10
                    border.color: "black"; border.width: 2
                    color: wifiOverlay.symbols ? "#DDDDDD" : "white"
                    Text {
                        anchors.centerIn: parent
                        text: wifiOverlay.symbols ? "abc" : "?123"
                        font.family: brandFont; font.pixelSize: 40; color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: wifiOverlay.symbols = !wifiOverlay.symbols
                    }
                }

                Rectangle {
                    width: 380; height: 95; radius: 10
                    border.color: "black"; border.width: 2; color: "white"
                    Text {
                        anchors.centerIn: parent; text: "space"
                        font.family: brandFont; font.pixelSize: 40; color: "black"
                    }
                    MouseArea { anchors.fill: parent; onClicked: wifiOverlay.typeChar(" ") }
                }

                Rectangle {
                    width: 250; height: 95; radius: 10
                    border.color: "black"; border.width: 2; color: "white"
                    Text {
                        anchors.centerIn: parent; text: "\u232B"
                        font.family: brandFont; font.pixelSize: 40; color: "black"
                    }
                    MouseArea { anchors.fill: parent; onClicked: wifiOverlay.backspace() }
                }
            }
        }
    }
}
