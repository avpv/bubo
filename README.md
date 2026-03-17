# Owlenda — macOS Menu Bar Calendar & Pomodoro App

A native macOS menu bar app for calendar events, meeting reminders, and Pomodoro focus sessions.

<p align="center">
  <img src="screenshots/menu-bar-overview.png" alt="Owlenda in menu bar" width="400">
</p>

## Features

### Calendar Sync

Owlenda syncs with **all calendars** configured in macOS — iCloud, Google, Exchange, Outlook, CalDAV, and any other account added via System Settings → Internet Accounts. No extra setup needed: if it shows up in Calendar.app, it shows up in Owlenda.

<p align="center">
  <img src="screenshots/calendar-sync.gif" alt="Calendar sync demo" width="500">
</p>

### Local Events

Create events directly in Owlenda without leaving the menu bar. Set title, date, time, duration, location, and notes. Events are saved locally and persist between launches — no cloud account required.

<p align="center">
  <img src="screenshots/create-event.gif" alt="Creating a local event" width="400">
</p>

### Pomodoro Timer

Built-in Pomodoro technique support. Set work intervals (e.g. 25 min) with automatic breaks. Long breaks are configurable after a set number of rounds. Full-screen alerts notify you when it's time to take a break or get back to work.

<p align="center">
  <img src="screenshots/pomodoro.gif" alt="Pomodoro timer demo" width="400">
</p>

### Reminders & Notifications

- **Customizable reminder intervals** — add any number of reminders (1, 5, 10, 30 min, etc.)
- **Full-screen notifications** with live countdown — never miss a meeting
- **Snooze** — 5, 10, or 15 minutes
- **Do Not Disturb** — set quiet hours so you're not disturbed at night

<p align="center">
  <img src="screenshots/full-screen-alert.png" alt="Full-screen alert" width="600">
</p>

### More

- **Recurring events** — daily, weekly, monthly, yearly (RFC 5545 RRULE)
- **Offline mode** — cached events available without internet
- **Grouped by day** — Today, Tomorrow, and beyond
- **Launch at login** — always ready in the menu bar
- **Dark mode** — follows macOS appearance

## Requirements

- macOS 13.0 (Ventura) or later

## Installation

### Option A: One command install (easiest)

```bash
curl -fsSL https://raw.githubusercontent.com/avpv/owlenda/HEAD/scripts/install.sh | bash
```

### Option B: Download DMG manually

1. Go to [Releases](https://github.com/avpv/owlenda/releases/latest)
2. Download **Owlenda.dmg**
3. Open the DMG and drag **Owlenda** to **Applications**
4. Run `xattr -cr /Applications/Owlenda.app` and launch

### Option C: Using Xcode

1. Install **Xcode** from the [Mac App Store](https://apps.apple.com/app/xcode/id497799835)
2. Launch Xcode once to accept the license and install components
3. Clone and open the project:

```bash
git clone https://github.com/avpv/owlenda.git
cd Owlenda
open -a Xcode Package.swift
```

4. Press **Cmd+R** to build and run

### Option D: Using Command Line Tools only (without Xcode)

1. Install Command Line Tools (if not already installed):

```bash
xcode-select --install
```

2. Clone, build, and run:

```bash
git clone https://github.com/avpv/owlenda.git
cd Owlenda
swift build -c release
.build/release/Owlenda
```

## Calendar Setup

Owlenda uses the native macOS Calendar integration (EventKit). To add calendars:

1. Open **System Settings → Internet Accounts**
2. Add your account (iCloud, Google, Exchange, etc.)
3. Enable **Calendars** for that account
4. Launch Owlenda → Settings → Calendars → grant access and select which calendars to show

## Architecture

The project follows MVVM (Model–View–ViewModel) pattern with a service layer.

## Project Structure

```
Owlenda/
├── Package.swift
├── README.md
└── Owlenda/
    ├── App.swift                              # Entry point, menu bar setup
    ├── AppDelegate.swift                      # Full-screen alert window management
    ├── Info.plist
    │
    ├── Models/
    │   ├── CalendarEvent.swift                # Event data model
    │   ├── RecurrenceRule.swift               # Recurrence rules & Pomodoro support
    │   └── ReminderSettings.swift             # User settings with auto-save
    │
    ├── ViewModels/
    │   └── SettingsViewModel.swift            # Settings async logic
    │
    ├── Views/
    │   ├── MenuBarView.swift                  # Main menu bar popover
    │   ├── SettingsView.swift                 # Settings tab container
    │   ├── AddEventView.swift                 # Event creation & editing form
    │   ├── EventDetailView.swift              # Event detail display
    │   ├── FullScreenAlertView.swift          # Full-screen reminder with countdown
    │   ├── DesignSystem.swift                 # Design tokens (spacing, colors)
    │   ├── Settings/
    │   │   ├── CalendarsTabView.swift         # Calendar access & selection
    │   │   ├── RemindersTabView.swift         # Intervals, notifications, DND
    │   │   └── GeneralTabView.swift           # Sync interval, startup
    │   └── Components/
    │       ├── OwlIcon.swift                  # Programmatic owl icon
    │       ├── DaySectionView.swift           # Day group header + events
    │       ├── EventRowView.swift             # Single event row
    │       ├── RecurrencePickerView.swift     # Recurrence & Pomodoro picker
    │       ├── TimeSlotPicker.swift           # Time selection
    │       ├── StatusBannerView.swift         # Status message banner
    │       └── ToastView.swift                # Toast notifications
    │
    ├── Services/
    │   ├── ReminderService.swift              # Sync, scheduling, notifications
    │   ├── RecurrenceExpander.swift            # Expand recurring events
    │   ├── EventCache.swift                   # Offline event persistence
    │   ├── NetworkMonitor.swift               # Network status detection
    │   └── Apple/
    │       └── AppleCalendarService.swift     # EventKit integration
    │
    ├── Utils/
    │   └── ICalDateParser.swift               # iCal date format parser
    │
    └── Resources/
        ├── AppIcon.icns                       # App icon
        └── MenuBarIcon.png                    # Menu bar icon
```
