import QtQuick
import QtTest
import "../../" as Plugin

// The music folder is edited in a real TextInput so the caret, selection,
// paste and the tilde key all come from Qt rather than a hand-written keymap.
// What is worth pinning here is that the input is wired to the shared draft:
// typing and pasting change the draft, and changes made through the panel's
// fallback keymap change the text and caret the native editor shows.
TestCase {
    id: test
    name: "SettingsEditor"

    Plugin.GrimPlayerConfig { id: config }

    Plugin.GrimPlayerSettings {
        id: card
        width: 700
        height: 700
        config: config
        // The card normally gets its palette from the panel. Giving the test a
        // small one of its own keeps the colour bindings from warning about a
        // missing shell singleton.
        theme: QtObject {
            property color background: "#181825"
            property color foreground: "#cdd6f4"
            property color muted: "#a6adc8"
            property color accent: "#89b4fa"
            property color selectedFill: "#282738"
        }
    }

    function entryFor(key) {
        var list = config.entries
        for (var i = 0; i < list.length; i++)
            if (list[i].key === key) return list[i]
        return null
    }

    function init() {
        config.reset()
        card.index = 0
        card.editMode = false
    }

    function test_text_row_shows_a_native_editor() {
        var e = entryFor("musicDir")
        verify(e !== null)

        config.beginTextEdit(e)
        card.editMode = true

        var input = findChild(card, "draftInput")
        verify(input !== null, "the card has no text input")
        // qmltestrunner has no window, so an item's effective `visible` stays
        // false even when every binding says the editor is live. editorActive
        // is the binding itself, which is what this test can check.
        tryCompare(input, "editorActive", true)
        verify(input.cursorVisible, "the caret should be visible")
        verify(input.selectByMouse, "the path should be selectable")
        compare(input.text, config.textEditDraft)
        compare(input.cursorPosition, config.textEditCaret)
        compare(input.parent.objectName, "valueText")

        // Assigning text is what typing and pasting do to a TextInput. Mirroring
        // the draft back must not drag the caret to where it was before the
        // keystroke: Qt has already advanced it to the end of the new text.
        input.text = config.textEditDraft + "/x"
        compare(input.cursorPosition, input.text.length)
        compare(config.textEditCaret, input.text.length)

        // A tilde is an ordinary character there, not a key the panel must map.
        input.text = "/home/grim/~/Music"
        compare(config.textEditDraft, "/home/grim/~/Music")

        // The native caret is mirrored into the shared draft index, so the
        // fallback keymap would keep editing wherever the pointer put it.
        input.cursorPosition = 5
        compare(config.textEditCaret, 5)

        // Ctrl+A clears through the config; the input must show the empty draft
        // rather than keeping the text it had before the clear.
        config.textClear()
        compare(input.text, "")

        // The other direction: a keystroke that reached the panel's fallback
        // handler has to appear in the editor too.
        config.textKeyStroke("~/Music")
        compare(input.text, "~/Music")
        compare(input.cursorPosition, "~/Music".length)

        config.textMoveCaret(-2)
        compare(input.cursorPosition, "~/Music".length - 2)

        card.editMode = false
        tryCompare(input, "editorActive", false)
    }
}
