# CalendarReminder — macOS Menu Bar App for Yandex & Google Calendar

A native macOS menu bar app for meeting reminders with full-screen notifications.

## Features

- **Yandex Calendar sync** via CalDAV with OAuth 2.0 support
- **Google Calendar sync** via Google Calendar API
- **Customizable reminder intervals** (add/remove any)
- **Full-screen notifications** — never miss a meeting
- **Snooze** reminders (5, 10, 15 min)
- **Manual event creation**
- **Recurring events** (RRULE) — daily, weekly, monthly
- **Do Not Disturb** — set quiet hours
- **Offline mode** — cached events shown without internet
- **Security** — passwords/tokens stored in macOS Keychain
- **Grouped by day** — Today, Tomorrow, and beyond

## Requirements

- macOS 13.0 (Ventura) or later

## Installation

### Option A: Download ready-made app (easiest)

1. Go to [Releases](https://github.com/avpv/CalendarReminder/releases/latest)
2. Download **CalendarReminder.dmg**
3. Open the DMG and drag **CalendarReminder** to **Applications**
4. Launch from Applications (on first launch: right-click → Open → Open)

### Option B: Using Xcode

1. Install **Xcode** from the [Mac App Store](https://apps.apple.com/app/xcode/id497799835)
2. Launch Xcode once to accept the license and install components
3. Clone and open the project:

```bash
git clone https://github.com/avpv/CalendarReminder.git
cd CalendarReminder
open -a Xcode Package.swift
```

4. Press **Cmd+R** to build and run

### Option C: Using Command Line Tools only (without Xcode)

1. Install Command Line Tools (if not already installed):

```bash
xcode-select --install
```

2. Clone, build, and run:

```bash
git clone https://github.com/avpv/CalendarReminder.git
cd CalendarReminder
swift build -c release
.build/release/CalendarReminder
```

## Authorization Setup

### Option 1: App Password (simpler)

1. Go to [id.yandex.ru](https://id.yandex.ru)
2. Security → App Passwords → Create
3. In the app: Settings → Account → enter login and password

### Option 2: OAuth 2.0 (more secure)

1. Register an app at [oauth.yandex.ru](https://oauth.yandex.ru/)
2. Set `yandexClientId` and `yandexClientSecret` in `Config/AppConfig.swift`
3. In the app: Settings → Account → OAuth → authorize via browser

### Option 3: Google Calendar

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/)
2. Enable Google Calendar API
3. Create OAuth 2.0 credentials (Desktop app)
4. Set `googleClientId` and `googleClientSecret` in `Config/AppConfig.swift`
5. In the app: Settings → Account → Enable Google Calendar → authorize

## Architecture

The project follows MVVM (Model–View–ViewModel) pattern with a service layer.

## Project Structure

```
CalendarReminder/
├── Package.swift
├── README.md
└── CalendarReminder/
    ├── App.swift                                  # Entry point, scene setup
    ├── AppDelegate.swift                          # Full-screen alert window management
    ├── Info.plist
    │
    ├── Config/
    │   └── AppConfig.swift                        # OAuth credentials, API URLs
    │
    ├── Models/
    │   ├── CalendarEvent.swift                    # Event data model
    │   └── ReminderSettings.swift                 # Settings, DND, Keychain proxies
    │
    ├── ViewModels/
    │   └── SettingsViewModel.swift                # Async logic for settings UI
    │
    ├── Views/
    │   ├── MenuBarView.swift                      # Menu bar layout
    │   ├── SettingsView.swift                     # Settings tab container
    │   ├── AddEventView.swift                     # Manual event creation form
    │   ├── FullScreenAlertView.swift              # Full-screen reminder with countdown
    │   ├── Settings/
    │   │   ├── AccountTabView.swift               # Yandex & Google auth
    │   │   ├── CalendarsTabView.swift             # Calendar selection
    │   │   ├── RemindersTabView.swift             # Intervals, notifications, DND
    │   │   └── GeneralTabView.swift               # Sync settings, status
    │   └── Components/
    │       ├── StatusBannerView.swift             # Status message banner
    │       ├── DaySectionView.swift               # Day group header + events
    │       └── EventRowView.swift                 # Single event row
    │
    ├── Services/
    │   ├── ReminderService.swift                  # Sync, scheduling, notifications
    │   ├── EventCache.swift                       # Offline event persistence
    │   ├── NetworkMonitor.swift                   # Network status + retry helper
    │   ├── KeychainService.swift                  # Secure credential storage
    │   ├── CalDAVXMLParser.swift                  # CalDAV XML response parser
    │   ├── ICalParser.swift                       # iCal parser (RRULE, timezones)
    │   ├── Yandex/
    │   │   ├── YandexCalDAVService.swift          # Yandex CalDAV sync
    │   │   └── YandexOAuthService.swift           # Yandex OAuth 2.0
    │   └── Google/
    │       ├── GoogleCalendarService.swift        # Google Calendar API
    │       └── GoogleOAuthService.swift           # Google OAuth 2.0
    │
    └── Resources/
```
