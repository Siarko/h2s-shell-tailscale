import QtQuick
import qs.api

// The public button that asks first (`confirm`), taking its question back when it hides and
// when what it acts on changes (`subject`): a question asked about one share, account or
// route never carries over to another, nor to the same button shown again later, where one
// click would then act at once.
//
//   ConfirmButton { kind: "danger"; label: "Remove"; subject: entry.key; onClicked: … }
SmallButton {
    // What the button acts on, as a string (an account's id, a share's key)
    property string subject: ""

    confirm: true
    onSubjectChanged: asking = false
    // `visible` is the effective one: a row or section hidden around it counts too
    onVisibleChanged: if (!visible) asking = false
}
