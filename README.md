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
- Xcode 15+

## Installation

```bash
git clone https://github.com/avpv/CalendarReminder.git
cd CalendarReminder/CalendarReminder
open -a Xcode Package.swift
# Press Cmd+R in Xcode to build and run
```

## Authorization Setup

### Option 1: App Password (simpler)

1. Go to [id.yandex.ru](https://id.yandex.ru)
2. Security → App Passwords → Create
3. In the app: Settings → Account → enter login and password

### Option 2: OAuth 2.0 (more secure)

1. Register an app at [oauth.yandex.ru](https://oauth.yandex.ru/)
2. Set `clientId` and `clientSecret` in `YandexOAuthService.swift`
3. In the app: Settings → Account → OAuth → authorize via browser

### Option 3: Google Calendar

1. Create a project in [Google Cloud Console](https://console.cloud.google.com/)
2. Enable Google Calendar API
3. Create OAuth 2.0 credentials (Desktop app)
4. Set `clientId` and `clientSecret` in `GoogleOAuthService.swift`
5. In the app: Settings → Account → Enable Google Calendar → authorize

## Project Structure

```
CalendarReminder/
├── Package.swift
└── CalendarReminder/
    ├── App.swift                        # Entry point
    ├── AppDelegate.swift                # Full-screen notifications + snooze
    ├── Info.plist
    ├── Models/
    │   ├── CalendarEvent.swift          # Event model
    │   └── ReminderSettings.swift       # Settings (DND, auth, Keychain)
    ├── Services/
    │   ├── KeychainService.swift        # Secure password storage
    │   ├── YandexOAuthService.swift     # Yandex OAuth 2.0
    │   ├── GoogleOAuthService.swift     # Google OAuth 2.0
    │   ├── YandexCalDAVService.swift    # CalDAV sync + retry
    │   ├── GoogleCalendarService.swift  # Google Calendar API
    │   ├── CalDAVXMLParser.swift        # XML parser
    │   ├── ICalParser.swift             # iCal parser with RRULE and timezones
    │   ├── ReminderService.swift        # Reminders, snooze, DND, cache
    │   ├── NetworkMonitor.swift         # Network monitoring + retry
    │   └── EventCache.swift             # Offline event cache
    └── Views/
        ├── MenuBarView.swift            # Menu bar with day grouping
        ├── SettingsView.swift           # Settings (OAuth, DND, intervals)
        └── AddEventView.swift           # Manual event creation
```
