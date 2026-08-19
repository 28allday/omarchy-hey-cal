# HEY

Your HEY Imbox and your next few calendar events, in one panel on your Omarchy
desktop. Press the shortcut, glance, press `↵` to open whatever you were
looking at in the browser, and get back to what you were doing.

It is a **native plugin for the Omarchy 4 desktop shell** (`omarchy-shell`):
an envelope in the bar, and a card that drops out of it.

<p align="center">
  <img src="docs/panel.png" width="70%" alt="The panel: recent Imbox threads with the next few calendar events underneath">
</p>

The top of the card is the **Imbox** — the ten most recent threads, unread ones
in bold with a dot, each showing who it is from, a snippet, the thread size and
how long ago it moved. Underneath, in its own slab, is **Up next**: the next few
things on your HEY Calendar, whichever calendar they live on.

Everything is **read-only**. Nothing here marks mail seen, archives, replies or
sends, and nothing edits your calendar. The panel shows you what is there and
gets out of the way.

## Requirements

- **Omarchy 4** (the `omarchy-shell` desktop).
- **[hey-cli](https://github.com/basecamp/hey-cli)** — HEY's own command-line
  client, from 37signals. The plugin never sees your password or token; it asks
  the `hey` command for data the same way you would at a prompt.

  There are no published binaries, so it is a build from source (Go 1.26+):

  ```sh
  git clone https://github.com/basecamp/hey-cli
  cd hey-cli
  mise install    # Go 1.26
  make install    # builds and installs /usr/local/bin/hey
  hey auth login  # browser-based OAuth
  ```

  Don't reach for the AUR `hey-cli` package: it pins a `v0.0.1` tag that does
  not exist upstream, so the download 404s.

  `hey auth status` should be happy before you open the panel. If it isn't, the
  panel tells you so rather than showing an empty list.
- **jq**, which is almost certainly already installed.

`hey-cli` publishes no tags or releases, so there is no version to pin to and
its JSON can move under us. This plugin was built and verified against build
`22aeea7`. If a fetch ever comes back wrong after you update the CLI, that is
the first thing to suspect.

## Install

```sh
omarchy plugin add https://github.com/28allday/omarchy-hey-cal.git
omarchy-shell shell rescanPlugins
omarchy plugin enable nosignal.hey-cal --section right
```

That puts an envelope in the right-hand side of your bar. Click it to open the
panel.

To reach it from the keyboard, add a binding to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + ALT + H", "HEY", "omarchy-shell shell toggle nosignal.hey-cal")
```

Bindings are picked up as soon as you save the file.

## Using it

| Key | Does |
| --- | --- |
| `↓` `↑` or `j` `k` | Move the cursor. It runs through the mail and straight on into the agenda. |
| `Home` `End` | First row / last row. |
| `↵` | Open the selected row in your browser — a mail thread at that thread, an event at that event. |
| `r` or `F5` | Fetch again. |
| `Esc` or `q` | Close. Clicking outside the card closes it too. |

The mouse does the same things: hover to move the cursor, click a row to open
it.

## How much it shows

Ten threads and four events, which is what fits without the card becoming a
second inbox. If the Imbox has more, a line under the list tells you how many
are waiting.

Both numbers live at the top of `Panel.qml` and are a one-line change each:

```qml
property int mailLimit: 10
property int eventLimit: 4
```

Only events that are still ahead of you are listed. A timed event stays up
until it ends; an all-day event stays up for the whole of its day.

## What it does on your machine

Worth knowing before you install anything that can read your mail:

- **It fetches only when you open it.** Nothing polls. Close the panel and it
  makes no requests at all; leave it open and it still makes none until you
  press `r`. The bar icon is a static icon, not a live unread badge — a badge
  would mean hitting HEY on a timer, which is the one thing this deliberately
  does not do.
- **It reads, it never writes.** The only commands it runs are `hey box imbox`,
  `hey calendars` and `hey recordings`, all with `--json`.
- **It stores nothing.** No cache, no mail on disk, no credentials — your HEY
  session lives in `hey-cli`'s own keyring entry and is never read here.
- **It writes one line to your shell config.** The first time the panel opens it
  adds `{"id": "nosignal.hey-cal"}` to the `plugins[]` array in
  `~/.config/omarchy/shell.json`, if it is not already there. This is what keeps
  the keyboard shortcut working when the bar icon is not in the bar — without
  it, removing the icon silently kills the shortcut. It is idempotent, it adds
  only that one entry, it never removes anything, and it writes through a
  temporary file. `omarchy plugin remove nosignal.hey-cal` clears it.
- **Opening a row launches your browser**, whichever one you have set as
  default, through Omarchy's own `omarchy-launch-browser`. Only `https://` links
  are ever passed on.
- Subjects, senders and snippets are rendered as **plain text**, never as
  markup, so nothing in an email can draw or load anything in your bar.

## Scope

- **Imbox only.** Not the Feed, Reply Later, Set Aside, Paper Trail or Bubble
  Up. If it is not in the Imbox it is not here.
- **Events only.** Habits and todos are not shown; this is an agenda, not a task
  list.
- **No composing.** Open the thread in HEY to reply.

## Related

Two single-purpose plugins do the halves separately, if that suits you better:
one is the Imbox on its own, the other the full 30-day agenda grouped by day.
This one is the merge of the two.

## Licence

MIT — see [LICENSE](LICENSE).

Not affiliated with, endorsed by, or connected to Basecamp or HEY.
