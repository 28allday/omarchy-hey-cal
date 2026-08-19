import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Combined HEY panel — the top of the Imbox with the next few calendar events
// pinned underneath. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle nosignal.hey-cal
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves (see onShellChanged).
//
// A merge of the two single-purpose siblings (nosignal.hey-mail and
// nosignal.hey-calendar), which stay shippable on their own. Everything comes
// from the `hey` CLI (HEY's own OAuth, token in the keyring — nothing stored
// here):
//   `hey box imbox --json`   → .data.postings[] → the mail list (top N)
//   `hey calendars --json` + `hey recordings <id> --json` → the agenda
// Both run ONCE when the panel opens, concurrently (r / F5 refetches) — no
// polling while open, none while closed.
//
// Read-only. Clicking or ↵ opens the selected row in the default browser via
// the first-party omarchy-launch-browser — a mail thread at its topic, an
// agenda row at the event itself (HEY's own `edit_url`, which is the event's
// page in HEY Calendar). Nothing mutates mail or calendar state.
//
// Fully generic: no hardcoded account, user, home or browser.
Item {
  id: root

  property bool opened: false

  readonly property string selfId: "nosignal.hey-cal"

  // How much of each source the panel shows. The Imbox is fetched whole (the
  // unread tally counts all of it) and sliced here; the agenda is filtered to
  // what is still ahead of now, then sliced. One-line edits.
  property int mailLimit: 10
  property int eventLimit: 4

  // Injected by the shell host after the Loader resolves. Used to keep the
  // host's open-flag honest on close(), and to self-restore if the host's
  // panel Instantiator rebuild destroys a visibly-open instance (its
  // openPanelIds flag survives the rebuild; our `opened` does not).
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // Mail state. mail: every Imbox thread, newest first; shown: the first
  // mailLimit of them, which is what the list and the cursor index into.
  // [{ id, subject, from, summary, seen, at, count, url }]
  property var mail: []
  property var shown: []
  property int unreadCount: 0
  property bool mailLoaded: false
  property string mailError: ""   // "", "nojq", "nohey", "err"

  // Agenda state. events: the next eventLimit upcoming events, soonest first.
  // [{ day, time, title, cal, allDay, url }]
  property var events: []
  property bool calLoaded: false
  property string calError: ""    // "", "nojq", "nohey", "err"

  readonly property bool truncated: root.mail.length > root.shown.length

  // Selection cursor. One index space over both lists: 0 … shown.length-1 are
  // mail rows, the rest are agenda rows. j/k therefore walks straight out of
  // the Imbox and into the agenda, and ↵ opens whichever kind it lands on.
  property int selectedIndex: -1
  property bool cursorActive: true
  readonly property int itemCount: root.shown.length + root.events.length

  // Shares the [menu] surface tokens so themes that style the menu style this
  // panel too — same approach as the sibling panels.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color selBg: Color.menu.selectedBackground
  property color selText: Color.menu.selectedText
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.xxxl
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)

  // Mail row geometry — deterministic so keyboard scrolling can keep the
  // selection visible without probing delegate positions. Two text lines per
  // row, same proportions as the claude-sessions list.
  readonly property int rowPadV: Style.spacing.lg
  readonly property int rowPadH: Style.spacing.lg
  readonly property int rowGap: Style.spacing.xs
  readonly property int lineGap: Style.spacing.sm
  readonly property int titleLineH: Style.font.title + Style.spacing.xs
  readonly property int captionLineH: Style.font.caption + Style.spacing.xxs
  readonly property int rowH: root.rowPadV * 2 + root.titleLineH + root.lineGap + root.captionLineH
  // Unread-dot gutter. Always reserved so read and unread subjects line up.
  readonly property int dotSize: Style.space(8)
  readonly property int dotColW: Style.space(16)
  // The "…and N more" footer line, present only when the Imbox overflows.
  readonly property int moreRowH: root.captionLineH + Style.spacing.sm

  // Agenda geometry. The block is a fixed slab at the bottom of the card, so
  // its height has to be known before the mail list is given the rest.
  readonly property int sepH: Math.max(1, Style.space(1))
  readonly property int agendaHeaderH: Style.font.caption + Style.spacing.sm
  readonly property int evRowH: Style.font.title + Style.spacing.md * 2
  readonly property int dayColW: Style.space(86)
  readonly property int timeColW: Style.space(96)
  readonly property int agendaRowsH: {
    var n = Math.max(1, root.events.length)
    return n * root.evRowH + (n - 1) * root.rowGap
  }
  readonly property int agendaBlockH: root.sepH + Style.spacing.lg + root.agendaHeaderH
                                      + Style.spacing.md + root.agendaRowsH

  // ------------------------------------------------------- self-registration

  // Keep the keyboard shortcut working with the bar on, off, or absent.
  //
  // `omarchy plugin enable` writes only the `bar.layout` entry for a plugin
  // that is both a panel and a bar widget: PluginRegistry.setEnabled picks the
  // bar branch of an if/else chain, so the `plugins[]` push below it is never
  // reached. The panel is then enabled only for as long as its icon sits in
  // the bar — take the icon out, or never want one, and the shell stops
  // instantiating the panel, so `omarchy-shell shell toggle` exits 0 and does
  // nothing. That is what "the keybinding doesn't work" turns out to be.
  //
  // So the first time we open, claim a `plugins[]` reference of our own. That
  // reference is enough on its own, so from then on the shortcut survives the
  // icon being removed. Idempotent, writes through a temp file, and inert once
  // a shell that writes both references itself has landed.
  //
  // It cannot repair an install that is already switched off: with no
  // reference the shell never loads this panel, so none of this runs. That
  // case needs `omarchy plugin enable <id>` once.
  //
  // Harness: sh -c <script> plugin-selfref <id> — $0 is the label, $1 the id.
  property bool selfRefEnsured: false
  readonly property string ensureSelfRefScript: [
    'id="$1"',
    'f="$HOME/.config/omarchy/shell.json"',
    '[ -f "$f" ] || exit 0',
    'jq -e --arg id "$id" \'any(.plugins[]?; (.id // empty) == $id)\' "$f" >/dev/null && exit 0',
    'tmp="$f.selfref.$$"',
    'jq --arg id "$id" \'.plugins = ((.plugins // []) + [{id: $id}])\' "$f" > "$tmp" || {',
    '  rm -f "$tmp"; exit 1;',
    '}',
    '[ -s "$tmp" ] || { rm -f "$tmp"; exit 1; }',
    'mv "$tmp" "$f"'
  ].join("\n")

  function ensureSelfReference() {
    if (root.selfRefEnsured) return
    root.selfRefEnsured = true
    Quickshell.execDetached(["sh", "-c", root.ensureSelfRefScript, "plugin-selfref", root.selfId])
  }

  function open(payloadJson) {
    root.opened = true
    root.ensureSelfReference()
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    // Keep the host's openPanelIds in sync so an Esc-closed panel doesn't
    // wrongly self-restore on the next delegate rebuild.
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // Both sources refetch together; they are independent processes, so a dead
  // calendar never keeps the mail list from rendering (or the reverse).
  function refresh() {
    root.mailLoaded = false
    root.calLoaded = false
    mailProc.running = true
    calProc.running = true
  }

  // ------------------------------------------------------------ formatting

  // Compact relative time from an ISO-8601 stamp: "now", "5m", "3h", "2d",
  // "4w". Returns "" for anything unparseable rather than "NaN".
  function ago(iso) {
    if (!iso) return ""
    var t = new Date(iso).getTime()
    if (isNaN(t)) return ""
    var s = Math.max(0, (Date.now() - t) / 1000)
    if (s < 60) return "now"
    if (s < 3600) return Math.round(s / 60) + "m"
    if (s < 86400) return Math.round(s / 3600) + "h"
    if (s < 86400 * 7) return Math.round(s / 86400) + "d"
    return Math.round(s / 604800) + "w"
  }

  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear()
        && a.getMonth() === b.getMonth()
        && a.getDate() === b.getDate()
  }

  // Short day chip for the agenda's left column: "Today", "Tomorrow", "Wed 20".
  // Deliberately narrower than the standalone calendar panel's day headers —
  // four rows don't earn a grouped layout.
  function dayChip(d) {
    var now = new Date()
    if (root.sameDay(d, now)) return "Today"
    if (root.sameDay(d, new Date(now.getTime() + 86400000))) return "Tomorrow"
    return Qt.formatDate(d, "ddd d")
  }

  // "10:00", or "10:00–11:30" when the end is known and lands on the same day.
  // All-day events never reach here.
  function timeLabel(startDate, endsIso) {
    var s = Qt.formatTime(startDate, "hh:mm")
    if (!endsIso) return s
    var e = new Date(endsIso)
    if (isNaN(e.getTime()) || !root.sameDay(e, startDate)) return s
    return s + "–" + Qt.formatTime(e, "hh:mm")
  }

  // ------------------------------------------------------------- mail fetch

  // One shot. `hey box imbox --json` once, then jq emits one compact object per
  // thread — QML parses each line with JSON.parse, exactly like the sibling
  // panels. jq -c always emits single-line JSON, so a subject or summary
  // containing newlines can't break the one-object-per-line contract.
  //
  // Two gotchas encoded here:
  //  - an EMPTY box returns `.data.postings: null`, not [] — hence `// []`.
  //  - `.topic_id` is null on every posting in this CLI build; the topic id
  //    only survives in `.app_url`, which is what the browser needs anyway.
  // Markers guard missing tools and a dead HEY session.
  readonly property string mailScript: [
    "command -v jq >/dev/null 2>&1 || { echo '##NOJQ'; exit 0; }",
    "command -v hey >/dev/null 2>&1 || { echo '##NOHEY'; exit 0; }",
    "box=\"$(hey box imbox --json 2>/dev/null)\"",
    "printf '%s' \"$box\" | jq -e '.ok == true and (.data | type == \"object\")' >/dev/null 2>&1 || { echo '##ERR'; exit 0; }",
    "printf '%s' \"$box\" | jq -c '(.data.postings // [])[] | {id: (.id | tostring), subject: (if ((.name // \"\") == \"\") then \"(no subject)\" else .name end), from: (.creator.name // .creator.email_address // \"Unknown\"), summary: ((.summary // \"\") | .[0:160]), seen: (.seen == true), at: (.active_at // .created_at // \"\"), count: (.visible_entry_count // 1), url: (.app_url // \"\")}' 2>/dev/null"
  ].join("\n")

  function parseMail(raw) {
    var lines = String(raw || "").split("\n")
    var out = []
    var unread = 0
    var error = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      if (line === "##NOJQ") { error = "nojq"; continue }
      if (line === "##NOHEY") { error = "nohey"; continue }
      if (line === "##ERR") { error = "err"; continue }
      try {
        var j = JSON.parse(line)
        if (!j || !j.id) continue
        if (j.seen !== true) unread++
        out.push(j)
      } catch (e) {}
    }
    // Newest first. HEY already returns them in this order; sorting keeps the
    // list honest if that ever changes. Unparseable stamps sink to the bottom.
    out.sort(function(a, b) {
      var ta = new Date(a.at).getTime()
      var tb = new Date(b.at).getTime()
      if (isNaN(ta)) ta = 0
      if (isNaN(tb)) tb = 0
      return tb - ta
    })

    root.mailError = error
    root.unreadCount = unread
    root.mail = out
    root.shown = out.slice(0, Math.max(0, root.mailLimit))
    root.mailLoaded = true
    root.reconcileSelection()
  }

  // ----------------------------------------------------------- agenda fetch

  // Lists calendars, then serially pulls each one's recordings (serial keeps
  // stdout lines from interleaving) and emits one compact JSON object per
  // Calendar::Event over HEY's default window (today + 30 days). Merged across
  // calendars, filtered to what is still ahead, then cut to eventLimit here.
  // Habits and todos are deliberately excluded: this is an agenda.
  readonly property string calScript: [
    "command -v jq >/dev/null 2>&1 || { echo '##NOJQ'; exit 0; }",
    "command -v hey >/dev/null 2>&1 || { echo '##NOHEY'; exit 0; }",
    "cals=\"$(hey calendars --json 2>/dev/null)\"",
    "printf '%s' \"$cals\" | jq -e '.ok == true and (.data | type == \"array\")' >/dev/null 2>&1 || { echo '##ERR'; exit 0; }",
    "printf '%s' \"$cals\" | jq -r '.data[] | [(.id|tostring), (.name // \"Personal\")] | @tsv' | while IFS=\"$(printf '\\t')\" read -r id name; do",
    "hey recordings \"$id\" --json 2>/dev/null | jq -c --arg cal \"$name\" '(.data[\"Calendar::Event\"] // [])[] | {title: (.title // \"Untitled\"), starts: .starts_at, ends: .ends_at, allDay: (.all_day // false), cal: $cal, url: (.edit_url // \"\")}' 2>/dev/null",
    "done"
  ].join("\n")

  // Still ahead of us? A timed event survives until it ends (or, with no end,
  // until it starts); an all-day event survives for the whole of its day, so
  // "today" keeps showing it right up to midnight.
  function isUpcoming(ev) {
    var now = new Date()
    if (ev.allDay === true) {
      var todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate())
      var evStart = new Date(ev.startDate.getFullYear(), ev.startDate.getMonth(), ev.startDate.getDate())
      return evStart.getTime() >= todayStart.getTime()
    }
    var t = ev.startDate.getTime()
    if (ev.ends) {
      var e = new Date(ev.ends)
      if (!isNaN(e.getTime())) t = e.getTime()
    }
    return t >= now.getTime()
  }

  function parseCal(raw) {
    var lines = String(raw || "").split("\n")
    var evs = []
    var error = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      if (line === "##NOJQ") { error = "nojq"; continue }
      if (line === "##NOHEY") { error = "nohey"; continue }
      if (line === "##ERR") { error = "err"; continue }
      try {
        var j = JSON.parse(line)
        if (!j || !j.starts) continue
        var d = new Date(j.starts)
        if (isNaN(d.getTime())) continue
        j.startDate = d
        if (!root.isUpcoming(j)) continue
        evs.push(j)
      } catch (e) {}
    }
    evs.sort(function(a, b) { return a.startDate - b.startDate })

    var out = []
    for (var k = 0; k < evs.length && k < root.eventLimit; k++) {
      var ev = evs[k]
      out.push({
        day: root.dayChip(ev.startDate),
        time: ev.allDay === true ? "all day" : root.timeLabel(ev.startDate, ev.ends),
        title: ev.title,
        cal: ev.cal || "",
        allDay: ev.allDay === true,
        url: ev.url || ""
      })
    }
    root.calError = error
    root.events = out
    root.calLoaded = true
    root.reconcileSelection()
  }

  Process {
    id: mailProc
    command: ["sh", "-c", root.mailScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseMail(text)
    }
  }

  Process {
    id: calProc
    command: ["sh", "-c", root.calScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.parseCal(text)
    }
  }

  // ------------------------------------------------------------- selection

  function isSelectable(i) { return i >= 0 && i < root.itemCount }

  // Anything past the mail slice is an agenda row; subtracting shown.length
  // gives its index into events.
  function isEventIndex(i) { return i >= root.shown.length && i < root.itemCount }

  // Both fetches land independently, so each one re-checks the cursor rather
  // than assuming it owns it: mail may arrive after the agenda, and either may
  // come back empty.
  function reconcileSelection() {
    hoverGate.reset()
    if (root.itemCount === 0) { root.selectedIndex = -1; return }
    if (root.selectedIndex < 0 || root.selectedIndex >= root.itemCount)
      root.selectedIndex = 0
    root.cursorActive = true
    root.scrollTo(root.selectedIndex)
  }

  function beginNav() {
    hoverGate.reset()
    root.cursorActive = true
    if (!root.isSelectable(root.selectedIndex)) {
      root.selectedIndex = root.itemCount > 0 ? 0 : -1
      root.scrollTo(root.selectedIndex)
      return false
    }
    return true
  }

  function move(dir) {
    if (!root.beginNav()) return
    var i = root.selectedIndex + dir
    if (i < 0 || i >= root.itemCount) return
    root.selectedIndex = i
    root.scrollTo(i)
  }

  function selectEdge(fromEnd) {
    hoverGate.reset()
    root.cursorActive = true
    if (root.itemCount === 0) { root.selectedIndex = -1; return }
    root.selectedIndex = fromEnd ? root.itemCount - 1 : 0
    root.scrollTo(root.selectedIndex)
  }

  function rowY(i) { return i * (root.rowH + root.rowGap) }

  // Only the mail list scrolls; the agenda slab is always fully on screen, so
  // an agenda index has nothing to bring into view.
  function scrollTo(i) {
    if (i < 0 || i >= root.shown.length) return
    if (mailList.contentHeight <= mailList.height) { mailList.contentY = 0; return }
    var y = root.rowY(i)
    if (y < mailList.contentY)
      mailList.contentY = y
    else if (y + root.rowH > mailList.contentY + mailList.height)
      mailList.contentY = y + root.rowH - mailList.height
  }

  // --------------------------------------------------------------- open

  // Open the selected row in the default browser. omarchy-launch-browser is
  // the first-party helper — it resolves the default browser through
  // xdg-settings, launches it under uwsm-app via a transient systemd unit, and
  // focuses the window afterwards, so this never names a browser itself.
  // Passed as an argv array (no shell); every URL is one HEY handed us, never
  // user text.
  function openSelected(i) {
    if (!root.isSelectable(i)) return
    if (root.isEventIndex(i)) root.openEvent(i - root.shown.length)
    else root.openMail(i)
  }

  // Both URLs arrive over the network, so neither is trusted to be a web link
  // just because HEY sent it. Anything that is not plain https:// is dropped
  // rather than handed to the browser — that rules out file://, and the
  // javascript: and data: URLs a browser would otherwise execute in whatever
  // origin it lands in.
  function isSafeUrl(u) {
    return String(u || "").indexOf("https://") === 0
  }

  // Mail: the thread's own app_url.
  function openMail(i) {
    var m = root.shown[i]
    if (!m || !root.isSafeUrl(m.url)) return
    Quickshell.execDetached(["omarchy-launch-browser", m.url])
    root.close()
  }

  // Agenda: the event's `edit_url` — app.hey.com/calendar/events/<id>/edit,
  // which is the event's own page in HEY Calendar. It is the only per-event
  // URL the recordings payload carries; there is no read-only view URL to
  // prefer over it. A recurring event's occurrence carries its own dated form
  // (…/events/<id>/occurrences/<date>/edit), so ↵ lands on the instance you
  // picked rather than the series.
  function openEvent(k) {
    if (k < 0 || k >= root.events.length) return
    var e = root.events[k]
    if (!e || !root.isSafeUrl(e.url)) return
    Quickshell.execDetached(["omarchy-launch-browser", e.url])
    root.close()
  }

  // Only a genuine pointer move may steal the selection cursor — delegates
  // created or scrolled under a stationary mouse must not hijack keyboard
  // navigation.
  // The gate maps samples into one shared reference item so the cursor can
  // cross from the mail list into the agenda without a coordinate jump reading
  // as movement.
  PointerMoveGate {
    id: hoverGate
    referenceItem: card
  }

  // ------------------------------------------------------------------- UI

  function listContentH() {
    if (root.shown.length === 0) return root.rowH
    var h = root.shown.length * root.rowH + (root.shown.length - 1) * root.rowGap
    if (root.truncated) h += root.rowGap + root.moreRowH
    return h
  }

  // One mail row: highlight rectangle + unread dot + two text lines + gated
  // hover / click. NoButton hover MouseArea sits over a click MouseArea.
  component MailRow: Item {
    id: rowItem

    property int flatIndex: -1
    property var rowData: null
    readonly property bool selected: root.cursorActive && rowItem.flatIndex === root.selectedIndex
    readonly property bool unread: rowItem.rowData ? rowItem.rowData.seen !== true : false

    width: parent ? parent.width : 0
    height: root.rowH

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
      color: rowItem.selected ? root.selBg : "transparent"
    }

    Item {
      anchors.fill: parent
      anchors.leftMargin: root.rowPadH
      anchors.rightMargin: root.rowPadH
      anchors.topMargin: root.rowPadV
      anchors.bottomMargin: root.rowPadV

      // Line 1: [unread dot] subject (elides first) · thread size · time.
      Item {
        id: line1
        width: parent.width
        height: root.titleLineH

        Rectangle {
          id: dot
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: root.dotSize
          height: root.dotSize
          radius: width / 2
          color: root.accent
          visible: rowItem.unread
        }

        Text {
          id: timeText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: rowItem.rowData ? root.ago(rowItem.rowData.at) : ""
          color: root.foreground
          opacity: 0.55
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Thread size, shown only for real threads (a lone message says
        // nothing worth the pixels).
        Text {
          id: countText
          anchors.right: timeText.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          visible: rowItem.rowData ? Number(rowItem.rowData.count) > 1 : false
          text: (rowItem.rowData && Number(rowItem.rowData.count) > 1)
                ? Number(rowItem.rowData.count) + " msgs" : ""
          color: root.foreground
          opacity: 0.4
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Subject, sender and summary are attacker-controlled: anyone who can
        // email you picks them. QML's default textFormat is AutoText, which
        // renders anything Qt reads as markup — including <img>, which would
        // fetch a remote URL and turn the panel into a tracking pixel. Every
        // Text bound to network data below is therefore pinned to PlainText.
        Text {
          anchors.left: parent.left
          anchors.leftMargin: root.dotColW
          anchors.right: countText.visible ? countText.left : timeText.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          text: rowItem.rowData ? rowItem.rowData.subject : ""
          textFormat: Text.PlainText
          color: rowItem.selected ? root.selText : root.foreground
          // Unread carries the weight; read mail steps back without vanishing.
          opacity: rowItem.unread || rowItem.selected ? 1.0 : 0.75
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: rowItem.unread
          elide: Text.ElideRight
        }
      }

      // Line 2: sender · summary snippet (both dim, single line, elided).
      Item {
        id: line2
        anchors.left: parent.left
        anchors.leftMargin: root.dotColW
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: root.captionLineH

        Text {
          id: fromText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, line2.width * 0.35)
          text: rowItem.rowData ? rowItem.rowData.from : ""
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }

        Text {
          anchors.left: fromText.right
          anchors.leftMargin: Style.spacing.sm
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: (rowItem.rowData && rowItem.rowData.summary) ? rowItem.rowData.summary : ""
          textFormat: Text.PlainText
          color: root.foreground
          opacity: 0.45
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    // Click anywhere on the row opens the thread.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        root.cursorActive = true
        root.selectedIndex = rowItem.flatIndex
        root.openSelected(rowItem.flatIndex)
      }
    }

    // Hover-selects, but only on genuine pointer movement (hoverGate filters
    // the synthetic hover a scrolled/created delegate receives). NoButton so
    // clicks fall through to the MouseArea above.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function(mouse) {
        if (!hoverGate.moved(this, mouse)) return
        root.cursorActive = true
        root.selectedIndex = rowItem.flatIndex
      }
    }
  }

  // One agenda row: day chip · time · title · calendar name. Carries the same
  // cursor, hover and click behaviour as a mail row — clicking opens the event
  // in HEY Calendar — so the whole card reads as one list.
  component EventRow: Item {
    id: evItem

    property int flatIndex: -1
    property var rowData: null
    readonly property bool selected: root.cursorActive && evItem.flatIndex === root.selectedIndex
    readonly property bool openable: evItem.rowData ? root.isSafeUrl(evItem.rowData.url) : false

    width: parent ? parent.width : 0
    height: root.evRowH

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius > 0 ? Style.cornerRadius : Style.space(6)
      color: evItem.selected ? root.selBg : "transparent"
    }

    Item {
      anchors.fill: parent
      anchors.leftMargin: root.rowPadH
      anchors.rightMargin: root.rowPadH

      Text {
        id: dayText
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        width: root.dayColW
        text: evItem.rowData ? evItem.rowData.day : ""
        color: evItem.selected ? root.selText : root.accent
        opacity: 0.9
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        id: evTimeText
        anchors.left: dayText.right
        anchors.verticalCenter: parent.verticalCenter
        width: root.timeColW
        text: evItem.rowData ? evItem.rowData.time : ""
        color: evItem.selected ? root.selText : root.foreground
        opacity: (evItem.rowData && evItem.rowData.allDay) ? 0.45 : 0.6
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.italic: evItem.rowData ? evItem.rowData.allDay === true : false
        elide: Text.ElideRight
      }

      Text {
        id: evCalText
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: evItem.rowData ? evItem.rowData.cal : ""
        textFormat: Text.PlainText
        color: evItem.selected ? root.selText : root.foreground
        opacity: 0.4
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        anchors.left: evTimeText.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: evCalText.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        text: evItem.rowData ? evItem.rowData.title : ""
        textFormat: Text.PlainText
        color: evItem.selected ? root.selText : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        elide: Text.ElideRight
      }
    }

    // Click anywhere on the row opens the event. An event with no URL still
    // takes the cursor — it just has nowhere to go, so it keeps the arrow.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      cursorShape: evItem.openable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: {
        root.cursorActive = true
        root.selectedIndex = evItem.flatIndex
        root.openSelected(evItem.flatIndex)
      }
    }

    // Hover-selects on genuine pointer movement only, same gate as the mail
    // rows so the cursor crosses between the two lists cleanly.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onPositionChanged: function(mouse) {
        if (!hoverGate.moved(this, mouse)) return
        root.cursorActive = true
        root.selectedIndex = evItem.flatIndex
      }
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-hey-cal"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      // Wide like the mail sibling — subjects and summaries are prose. Height
      // capped at 80% of the screen; the mail list scrolls only on genuine
      // overflow, and the agenda slab always keeps its full height.
      width: Math.min(Style.space(640), panel.width - Style.gapsOut * 2)
      height: Math.min(
        card.contentTopInset + card.contentBottomInset
          + root.headerHeight + root.contentSpacing + root.listContentH()
          + root.contentSpacing + root.agendaBlockH,
        Math.min(panel.height * 0.8, panel.height - Style.bar.sizeHorizontal - Style.gapsOut * 2))
      radius: root.cornerRadius
      // Top-right, tucked under the bar — same spot the first-party
      // network/bluetooth popups land.
      anchors.top: parent.top
      anchors.right: parent.right
      anchors.topMargin: Style.bar.sizeHorizontal + Style.gapsOut
      anchors.rightMargin: Style.gapsOut
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin
      clip: true

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape || event.key === Qt.Key_Q) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_R || event.key === Qt.Key_F5) {
            root.refresh()
            event.accepted = true
          } else if (event.key === Qt.Key_Up || event.key === Qt.Key_K) {
            root.move(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down || event.key === Qt.Key_J) {
            root.move(1)
            event.accepted = true
          } else if (event.key === Qt.Key_Home) {
            root.selectEdge(false)
            event.accepted = true
          } else if (event.key === Qt.Key_End) {
            root.selectEdge(true)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            root.openSelected(root.selectedIndex)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: titleText
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "󰇮  HEY"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
          }

          // Unread tally, accented so it reads at a glance. Counts the whole
          // Imbox, not just the slice on screen. Hidden when it's all read —
          // nothing to shout about.
          Text {
            anchors.left: titleText.right
            anchors.leftMargin: Style.spacing.md
            anchors.baseline: titleText.baseline
            visible: root.unreadCount > 0
            text: root.unreadCount + " unread"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "esc close · r refresh · ↵ open"
            color: root.foreground
            opacity: 0.45
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // -------------------------------------------------------- mail list
        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.agendaBlockH - root.contentSpacing * 2

          // Loading / error / empty note.
          Text {
            visible: root.shown.length === 0
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            text: !root.mailLoaded ? "Fetching mail…"
                : root.mailError === "nojq" ? "jq is required for this panel"
                : root.mailError === "nohey" ? "hey CLI not found — github.com/basecamp/hey-cli"
                : root.mailError === "err" ? "Couldn't reach HEY — try: hey auth status"
                : "Imbox is empty"
            color: root.mailError !== "" && root.mailLoaded ? root.urgent : root.foreground
            opacity: root.mailError !== "" && root.mailLoaded ? 1.0 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            wrapMode: Text.WordWrap
          }

          Flickable {
            id: mailList
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: rowsCol.implicitHeight
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: rowsCol
              width: mailList.width
              spacing: root.rowGap

              Repeater {
                model: root.shown

                delegate: MailRow {
                  required property int index
                  required property var modelData
                  flatIndex: index
                  rowData: modelData
                }
              }

              // What the slice left behind. The full Imbox lives one click
              // away, so this says how much rather than offering to show it.
              Item {
                visible: root.truncated
                width: rowsCol.width
                height: visible ? root.moreRowH : 0

                Text {
                  anchors.left: parent.left
                  anchors.leftMargin: root.rowPadH + root.dotColW
                  anchors.verticalCenter: parent.verticalCenter
                  text: "…and " + (root.mail.length - root.shown.length) + " more in the Imbox"
                  color: root.foreground
                  opacity: 0.4
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // ----------------------------------------------------- agenda slab
        Item {
          width: parent.width
          height: root.agendaBlockH

          Rectangle {
            id: sep
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: root.sepH
            color: root.border
            opacity: 0.5
          }

          Text {
            id: agendaHeader
            anchors.top: sep.bottom
            anchors.topMargin: Style.spacing.lg
            anchors.left: parent.left
            anchors.leftMargin: root.rowPadH
            height: root.agendaHeaderH
            verticalAlignment: Text.AlignVCenter
            text: "󰃭  UP NEXT"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          // Loading / error / empty note, in the space the rows would take.
          Text {
            visible: root.events.length === 0
            anchors.top: agendaHeader.bottom
            anchors.topMargin: Style.spacing.md
            anchors.left: parent.left
            anchors.leftMargin: root.rowPadH
            anchors.right: parent.right
            anchors.rightMargin: root.rowPadH
            height: root.evRowH
            verticalAlignment: Text.AlignVCenter
            text: !root.calLoaded ? "Fetching events…"
                : root.calError === "nojq" ? "jq is required for the agenda"
                : root.calError === "nohey" ? "hey CLI not found — github.com/basecamp/hey-cli"
                : root.calError === "err" ? "Couldn't reach HEY Calendar"
                : "Nothing else on the calendar"
            color: root.calError !== "" && root.calLoaded ? root.urgent : root.foreground
            opacity: root.calError !== "" && root.calLoaded ? 1.0 : 0.6
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
          }

          Column {
            anchors.top: agendaHeader.bottom
            anchors.topMargin: Style.spacing.md
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: root.rowGap

            Repeater {
              model: root.events

              delegate: EventRow {
                required property int index
                required property var modelData
                flatIndex: root.shown.length + index
                rowData: modelData
              }
            }
          }
        }
      }
    }
  }
}
