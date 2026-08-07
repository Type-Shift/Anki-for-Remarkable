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

    // Whether the Wi-Fi panel is open. Needed because running this app
    // requires stopping xochitl, which removes reMarkable's own settings UI.
    property bool wifiOpen: false

    // Fonts — scaled for reMarkable high-DPI (1872x2404)
    property string defaultFont: "sans-serif"
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

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -30
                    onClicked: anki.loadDecks()
                }
            }

            Text {
                text: {
                    if (anki.currentState === "STUDY" || anki.currentState === "DONE") return truncate(anki.currentDeckName, 30);
                    if (anki.currentState === "LOADING") return "reMarkable Anki";
                    if (anki.currentState === "ERROR") return "Error";
                    return "reMarkable Anki";
                }
                font.family: defaultFont
                font.pixelSize: headerFontSize
                color: "black"
            }
        }

        Item {
            anchors.right: parent.right
            anchors.rightMargin: 50
            anchors.verticalCenter: parent.verticalCenter
            width: 500
            height: parent.height

            Column {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: 400
                spacing: 12
                visible: anki.currentState === "STUDY"

                Text {
                    anchors.right: parent.right
                    text: "Remaining: " + anki.currentRemaining
                    font.family: defaultFont
                    font.pixelSize: smallFontSize
                    color: "black"
                }

                Rectangle {
                    width: parent.width
                    height: 16
                    color: "white"
                    border.color: "black"
                    border.width: 2

                    Rectangle {
                        anchors.left: parent.left
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.margins: 2
                        color: "black"
                        width: anki.currentTotal > 0
                               ? parent.width * (1 - (anki.currentRemaining / anki.currentTotal))
                               : 0
                        onWidthChanged: if (width < 0) width = 0
                    }
                }
            }
        }

        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 3
            color: "black"
        }
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

                            // Full-row tap → start studying this deck
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
        Item {
            id: studyScreen
            anchors.fill: parent
            visible: anki.currentState === "STUDY"

            MouseArea {
                anchors.fill: parent
                enabled: !isAnswerRevealed
                onClicked: isAnswerRevealed = true
            }

            Rectangle {
                id: flashcard
                width: parent.width - 120
                anchors.top: parent.top
                anchors.topMargin: 80
                anchors.horizontalCenter: parent.horizontalCenter

                radius: 24
                border.color: "black"
                border.width: 3
                color: "white"

                height: cardContents.height + 120

                Column {
                    id: cardContents
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.topMargin: 60
                    anchors.leftMargin: 60
                    anchors.rightMargin: 60
                    spacing: 60

                    Text {
                        text: truncate(anki.currentDeckName, 30)
                        font.family: defaultFont
                        font.pixelSize: 36
                        color: "black"
                        opacity: 0.6
                    }

                    Text {
                        text: anki.currentFront
                        font.family: defaultFont
                        font.pixelSize: largeFontSize
                        color: "black"
                        wrapMode: Text.WordWrap
                        width: parent.width
                    }

                    Text {
                        text: "(tap to reveal answer)"
                        font.family: defaultFont
                        font.pixelSize: smallFontSize
                        color: "black"
                        opacity: 0.4
                        visible: !isAnswerRevealed
                        anchors.horizontalCenter: parent.horizontalCenter
                    }

                    Item {
                        width: parent.width
                        height: 4
                        visible: isAnswerRevealed
                        clip: true

                        Row {
                            spacing: 16
                            Repeater {
                                model: 100
                                Rectangle {
                                    width: 12
                                    height: 4
                                    color: "black"
                                    opacity: 0.5
                                }
                            }
                        }
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
                }
            }
        }
    }

    // Reset isAnswerRevealed when a new card is shown
    Connections {
        target: anki
        function onCurrentFrontChanged() {
            isAnswerRevealed = false
        }
    }

    // 3. Footer Area
    Item {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: (anki.currentState === "STUDY" && isAnswerRevealed) ? 300 : 80

        RowLayout {
            id: ratingButtons
            anchors.bottom: statusBar.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottomMargin: 30
            height: 180
            visible: anki.currentState === "STUDY" && isAnswerRevealed
            spacing: 40

            Item { Layout.fillWidth: true }

            Repeater {
                model: {
                    var labels = anki.currentButtonLabels;
                    var colors = ["#D32F2F", "#F57C00", "#388E3C", "#0288D1"];
                    var names  = ["Again", "Hard", "Good", "Easy"];
                    var items  = [];
                    for (var i = 0; i < labels.length && i < 4; i++) {
                        items.push({
                            label:  names[i] || ("Btn " + (i+1)),
                            time:   labels[i],
                            color:  colors[i] || "#333333",
                            button: i + 1
                        });
                    }
                    return items;
                }

                delegate: Column {
                    spacing: 16
                    Layout.alignment: Qt.AlignHCenter | Qt.AlignBottom

                    Text {
                        text: modelData.time
                        anchors.horizontalCenter: parent.horizontalCenter
                        font.family: defaultFont
                        font.pixelSize: smallFontSize
                        color: "black"
                    }

                    Rectangle {
                        width: 260
                        height: 110
                        radius: 24
                        border.color: modelData.color
                        border.width: 5
                        color: "white"

                        Text {
                            anchors.centerIn: parent
                            text: modelData.label
                            font.family: defaultFont
                            font.pixelSize: normalFontSize
                            color: modelData.color
                            font.bold: true
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: anki.answerCard(modelData.button)
                        }
                    }
                }
            }

            Item { Layout.fillWidth: true }
        }

        Item {
            id: statusBar
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 80

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
                text: "v1.0.0 - Jayy001 - ReMarkable"
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
        visible: anki.currentState === "LOGIN"
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
            if (emailInput.length > 0 && passwordInput.length > 0)
                anki.login(emailInput, passwordInput)
        }

        // White background
        Rectangle {
            anchors.fill: parent
            color: "white"
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
                text: "Sign in to AnkiWeb"
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
    Item {
        id: wifiOverlay
        anchors.fill: parent
        visible: root.wifiOpen
        z: 200

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
            // A saved network already has credentials stored; don't force
            // the user to retype a password they've entered before.
            if (selectedSaved && passwordInput === "")
                wifi.connectToSaved(selectedSsid)
            else
                wifi.connectToNetwork(selectedSsid, passwordInput)
            passwordInput = ""
        }

        Rectangle { anchors.fill: parent; color: "white" }

        // ---- Header ----
        Item {
            id: wifiHeader
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 140

            Text {
                anchors.left: parent.left
                anchors.leftMargin: 50
                anchors.verticalCenter: parent.verticalCenter
                text: "Wi-Fi"
                font.family: defaultFont
                font.pixelSize: largeFontSize
                font.bold: true
                color: "black"
            }

            Text {
                anchors.right: parent.right
                anchors.rightMargin: 50
                anchors.verticalCenter: parent.verticalCenter
                text: "Close ✕"
                font.family: defaultFont
                font.pixelSize: headerFontSize
                color: "black"

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -30
                    onClicked: root.wifiOpen = false
                }
            }
        }

        Rectangle {
            id: wifiDivider
            anchors.top: wifiHeader.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            height: 3
            color: "black"
        }

        // ---- Status + actions ----
        Column {
            id: wifiStatusBlock
            anchors.top: wifiDivider.bottom
            anchors.topMargin: 30
            anchors.left: parent.left
            anchors.leftMargin: 50
            anchors.right: parent.right
            anchors.rightMargin: 50
            spacing: 16

            Text {
                text: wifi.connected
                      ? ("Connected to " + wifi.currentSsid)
                      : (wifi.status === "CONNECTING" ? "Connecting..." : "Not connected")
                font.family: defaultFont
                font.pixelSize: normalFontSize
                font.bold: true
                color: "black"
            }

            Text {
                text: wifi.ipAddress === "" ? " " : ("IP " + wifi.ipAddress)
                font.family: defaultFont
                font.pixelSize: smallFontSize
                color: "#555555"
            }

            Text {
                text: wifi.wifiError
                visible: wifi.wifiError !== ""
                font.family: defaultFont
                font.pixelSize: smallFontSize
                color: "#D32F2F"
                wrapMode: Text.WordWrap
                width: parent.width
            }

            Row {
                spacing: 24

                Rectangle {
                    width: 300; height: 90; radius: 20
                    border.color: "black"; border.width: 4; color: "white"
                    Text {
                        anchors.centerIn: parent
                        text: wifi.scanning ? "Scanning..." : "Scan"
                        font.family: defaultFont
                        font.pixelSize: smallFontSize
                        color: "black"
                    }
                    MouseArea { anchors.fill: parent; onClicked: wifi.scan() }
                }

                Rectangle {
                    width: 340; height: 90; radius: 20
                    border.color: "black"; border.width: 4; color: "white"
                    Text {
                        anchors.centerIn: parent
                        text: wifi.connected ? "Turn off Wi-Fi" : "Turn on Wi-Fi"
                        font.family: defaultFont
                        font.pixelSize: smallFontSize
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: wifi.connected ? wifi.disconnectWifi() : wifi.reconnectWifi()
                    }
                }

                Rectangle {
                    width: 300; height: 90; radius: 20
                    visible: wifiOverlay.selectedSaved && wifiOverlay.selectedSsid !== ""
                    border.color: "#D32F2F"; border.width: 4; color: "white"
                    Text {
                        anchors.centerIn: parent
                        text: "Forget"
                        font.family: defaultFont
                        font.pixelSize: smallFontSize
                        color: "#D32F2F"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: {
                            wifi.forgetNetwork(wifiOverlay.selectedSsid)
                            wifiOverlay.selectedSsid = ""
                        }
                    }
                }
            }
        }

        // ---- Network list ----
        Flickable {
            id: netList
            anchors.top: wifiStatusBlock.bottom
            anchors.topMargin: 30
            anchors.left: parent.left
            anchors.leftMargin: 50
            anchors.right: parent.right
            anchors.rightMargin: 50
            anchors.bottom: wifiKeyboard.top
            anchors.bottomMargin: 20
            contentHeight: netColumn.height
            clip: true

            Column {
                id: netColumn
                width: parent.width
                spacing: 0

                Text {
                    text: wifi.networks.length === 0
                          ? "No networks found yet - tap Scan."
                          : ""
                    visible: wifi.networks.length === 0
                    font.family: defaultFont
                    font.pixelSize: smallFontSize
                    color: "#555555"
                    topPadding: 20
                }

                Repeater {
                    model: wifi.networks

                    delegate: Rectangle {
                        width: netColumn.width
                        height: 120
                        color: modelData.ssid === wifiOverlay.selectedSsid ? "#E8E8E8" : "white"

                        Row {
                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 24

                            Text {
                                // Simple bar meter; e-paper renders blocks well.
                                text: {
                                    var b = modelData.bars
                                    var s = ""
                                    for (var i = 0; i < 4; i++) s += (i < b ? "█" : "░")
                                    return s
                                }
                                font.family: "monospace"
                                font.pixelSize: smallFontSize
                                color: "black"
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                text: modelData.ssid
                                font.family: defaultFont
                                font.pixelSize: normalFontSize
                                font.bold: modelData.current
                                color: "black"
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                text: modelData.secured ? "(WPA)" : "(open)"
                                font.family: defaultFont
                                font.pixelSize: smallFontSize
                                color: "#555555"
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            Text {
                                text: modelData.current ? "connected"
                                                        : (modelData.saved ? "saved" : "")
                                font.family: defaultFont
                                font.pixelSize: smallFontSize
                                color: "#555555"
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        Rectangle {
                            anchors.bottom: parent.bottom
                            width: parent.width
                            height: 2
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

        // ---- Password entry + keyboard ----
        Column {
            id: wifiKeyboard
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 20
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 100
            spacing: 14
            // Only needed when joining a secured network we have no password for.
            visible: wifiOverlay.selectedSsid !== "" &&
                     wifiOverlay.selectedSecured &&
                     !(wifiOverlay.selectedSaved && wifiOverlay.passwordInput === "")

            Row {
                spacing: 20
                width: parent.width

                Rectangle {
                    width: parent.width - 340
                    height: 100
                    radius: 16
                    border.color: "black"
                    border.width: 4
                    color: "white"

                    Text {
                        anchors.left: parent.left
                        anchors.leftMargin: 24
                        anchors.verticalCenter: parent.verticalCenter
                        text: wifiOverlay.passwordInput.length > 0
                              ? wifiOverlay.passwordInput
                              : ("Password for " + wifiOverlay.selectedSsid)
                        font.family: defaultFont
                        font.pixelSize: smallFontSize
                        color: wifiOverlay.passwordInput.length > 0 ? "black" : "#999999"
                        elide: Text.ElideRight
                        width: parent.width - 48
                    }
                }

                Rectangle {
                    width: 320; height: 100; radius: 16
                    border.color: "black"; border.width: 4; color: "white"
                    Text {
                        anchors.centerIn: parent
                        text: "Connect"
                        font.family: defaultFont
                        font.pixelSize: smallFontSize
                        font.bold: true
                        color: "black"
                    }
                    MouseArea { anchors.fill: parent; onClicked: wifiOverlay.join() }
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
                            width: 150; height: 100; radius: 12
                            border.color: "black"; border.width: 3; color: "white"
                            Text {
                                anchors.centerIn: parent
                                text: wifiOverlay.shifted && !wifiOverlay.symbols
                                      ? modelData.toUpperCase() : modelData
                                font.family: defaultFont
                                font.pixelSize: smallFontSize
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
                    width: 220; height: 100; radius: 12
                    border.color: "black"; border.width: 3
                    color: wifiOverlay.shifted ? "#DDDDDD" : "white"
                    Text {
                        anchors.centerIn: parent; text: "SHIFT"
                        font.family: defaultFont; font.pixelSize: smallFontSize; color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: wifiOverlay.shifted = !wifiOverlay.shifted
                    }
                }

                Rectangle {
                    width: 220; height: 100; radius: 12
                    border.color: "black"; border.width: 3
                    color: wifiOverlay.symbols ? "#DDDDDD" : "white"
                    Text {
                        anchors.centerIn: parent
                        text: wifiOverlay.symbols ? "abc" : "?123"
                        font.family: defaultFont; font.pixelSize: smallFontSize; color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        onClicked: wifiOverlay.symbols = !wifiOverlay.symbols
                    }
                }

                Rectangle {
                    width: 400; height: 100; radius: 12
                    border.color: "black"; border.width: 3; color: "white"
                    Text {
                        anchors.centerIn: parent; text: "space"
                        font.family: defaultFont; font.pixelSize: smallFontSize; color: "black"
                    }
                    MouseArea { anchors.fill: parent; onClicked: wifiOverlay.typeChar(" ") }
                }

                Rectangle {
                    width: 260; height: 100; radius: 12
                    border.color: "black"; border.width: 3; color: "white"
                    Text {
                        anchors.centerIn: parent; text: "⌫"
                        font.family: defaultFont; font.pixelSize: smallFontSize; color: "black"
                    }
                    MouseArea { anchors.fill: parent; onClicked: wifiOverlay.backspace() }
                }
            }
        }

        // Join button for open or already-saved networks, where no keyboard
        // is shown and there is nothing to type.
        Rectangle {
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 40
            anchors.horizontalCenter: parent.horizontalCenter
            width: 460; height: 110; radius: 20
            border.color: "black"; border.width: 4; color: "white"
            visible: wifiOverlay.selectedSsid !== "" && !wifiKeyboard.visible

            Text {
                anchors.centerIn: parent
                text: "Connect to " + truncate(wifiOverlay.selectedSsid, 14)
                font.family: defaultFont
                font.pixelSize: smallFontSize
                font.bold: true
                color: "black"
            }
            MouseArea { anchors.fill: parent; onClicked: wifiOverlay.join() }
        }
    }
}
