#!/usr/bin/env python3
"""Compose the F-Droid listing frames from raw emulator captures.

F-Droid keeps every filename an app has ever published (fdroidserver#490), so
stale shots can only be replaced by publishing new content under the same
names. Those names are listed here; the eight that already match the current
Play set are left alone.

Dark captures get their own frame palette: a listing where every card is the
same blue reads as one long image, and the dark shots sit better on a darker
backdrop than the light ones.
"""
import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
RAW = REPO / "screenshots" / "store-raw"

spec = importlib.util.spec_from_file_location(
    "mss", REPO / "scripts" / "make-store-screenshots.py")
mss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mss)

DARK_COLORS = {
    "bg_top": "#243452",
    "bg_mid": "#111A2B",
    "bg_bottom": "#05080F",
    "ink": "#FFFFFF",
    "frame": "#04060B",
    "button": "#0B1220",
    "shadow": "#000000",
}

# name, headline, subhead, dark
SHOTS = [
    ("01-home-dark.png", "Your conversations", "Groups, alerts and people in one list.", True),
    ("01-home.png", "Archived, still there", "Tuck a thread away without deleting it.", True),
    ("02-chat-dark.png", "Chat, dark theme", "Bubbles that stay readable at night.", True),
    ("02-chat-grouped-bubbles.png", "Group chats", "Every reply in one thread.", True),
    ("02-settings.png", "Settings", "Everything in one place.", True),
    ("03-chat-work.png", "Long threads", "The whole history is there when you scroll.", True),
    ("03-chat.png", "Read the history", "Nothing is cut off or paged in.", True),
    ("04-chat-alex.png", "Pick up the thread", "Conversations open instantly.", True),
    ("05-chat-otp.png", "One-time codes", "Spot the code you need.", True),
    ("06-new-chat.png", "Start a chat", "Search contacts or dial a number.", True),
    ("06-settings-dark.png", "General settings", "Notifications, theme and SIM.", True),
    ("06-typing.png", "Type a message", "Send when you are ready.", True),
    ("07-reply-dark.png", "Reply from the chat", "No app switching.", True),
    ("07-settings.png", "Advanced settings", "Fine-grained options.", True),
    ("07-sim-switcher.png", "SIM card", "See the line you are using.", True),
    ("08-spam-blocked.png", "Spam stays out", "Blocked senders never reach you.", True),
    ("09-spam-blocked-messages.png", "Filtered messages", "Review what was blocked.", True),
    ("10-auto-delete.png", "Auto-delete", "Decide how long messages stay.", True),
    ("10-settings-scroll-dark.png", "Privacy and app lock", "Further down the settings list.", True),
    ("11-scheduled-dark.png", "Scheduled messages", "Write now, send later.", True),
    ("13-trash-dark.png", "Trash", "Restore a chat you removed.", True),
    ("15-contact-details-dark.png", "Chat details", "Notifications and blocking per chat.", True),
    ("17-new-chat-dark.png", "Find a contact", "Type a name to filter.", True),
    ("19-archive-dark.png", "Archived chats", "Out of the inbox, still searchable.", True),
    ("21-search-dark.png", "Search messages", "Find a word across every chat.", True),
    ("22-starred-dark.png", "Starred messages", "Keep the texts worth keeping.", True),
    ("01-conversations.png", "Light theme", "Calm surfaces, clear text.", False),
    ("03-home-light.png", "Everything at a glance", "Unread, pinned and muted.", False),
    ("04-chat-light.png", "Chat in daylight", "Light bubbles, full contrast.", False),
    ("04-contact.png", "Group details", "Members and settings.", False),
    ("05-settings-light.png", "Settings in light", "Same options, brighter.", False),
    ("05-reaction.png", "React with one tap", "Say it without typing.", False),
    ("08-new-chat.png", "New conversation", "Contacts first, as they should be.", False),
    ("08-reply-light.png", "Quick reply", "Type and send.", False),
    ("09-settings-scroll-light.png", "Privacy settings", "App lock and privacy mode.", False),
    ("12-scheduled-light.png", "Send later", "Pick a time and a date.", False),
    ("14-trash-light.png", "Recently deleted", "Recover before it is gone.", False),
    ("16-contact-details-light.png", "Contact details", "Everything about this chat.", False),
    ("18-new-chat-light.png", "Search a name", "Filter your contacts.", False),
    ("20-archive-light.png", "Archived", "Filed, not deleted.", False),
    ("21-search-light.png", "Search", "Matching texts and conversations.", False),
    ("22-starred-light.png", "Favourites", "Starred messages, in one place.", False),
]

# The eight frames that already ship under the Play set.
KEEP = {
    "01-chats.png", "02-replying.png", "03-reactions.png", "04-new-chat.png",
    "05-contact.png", "06-themes.png", "07-advanced.png", "08-import.png",
}


def main():
    only = sys.argv[1] if len(sys.argv) > 1 else None
    mss.RAW_DIR = RAW
    mss.OUT_DIR.mkdir(parents=True, exist_ok=True)
    light = mss.palette()
    missing = []
    done = 0
    for name, headline, subhead, dark in SHOTS:
        if only and name != only:
            continue
        if not (RAW / name).exists():
            missing.append(name)
            continue
        colors = DARK_COLORS if dark else light
        mss.compose(name, name, headline, subhead, colors)
        done += 1
    print(f"composed {done}; missing raw {len(missing)}")
    for m in missing:
        print("  MISSING RAW", m)
    return 0 if not missing else 1


if __name__ == "__main__":
    sys.exit(main())
