# Reminder — macOS-приложение для Яндекс Календаря

Нативное macOS-приложение в менюбаре для напоминаний о встречах с полноэкранными уведомлениями.

## Возможности

- **Синхронизация с Яндекс Календарём** через CalDAV с поддержкой OAuth 2.0
- **Настраиваемые интервалы** напоминаний (добавляйте/удаляйте любые)
- **Полноэкранные уведомления** — точно не пропустите встречу
- **Откладывание** напоминаний (через 5, 10, 15 мин)
- **Ручное добавление** событий
- **Повторяющиеся события** (RRULE) — ежедневные, еженедельные, ежемесячные
- **Не беспокоить** — настройте часы тишины
- **Оффлайн-режим** — кэшированные события показываются без интернета
- **Безопасность** — пароли/токены хранятся в macOS Keychain
- **Группировка по дням** — Сегодня, Завтра и далее

## Требования

- macOS 13.0 (Ventura) или новее
- Xcode 15+

## Быстрый старт

```bash
cd YandexCalendarReminder
open Package.swift
# Нажмите Cmd+R в Xcode
```

## Настройка авторизации

### Вариант 1: Пароль приложения (проще)

1. Перейдите на [id.yandex.ru](https://id.yandex.ru)
2. Безопасность → Пароли приложений → Создать
3. В приложении: Настройки → Аккаунт → введите логин и пароль

### Вариант 2: OAuth 2.0 (безопаснее)

1. Зарегистрируйте приложение на [oauth.yandex.ru](https://oauth.yandex.ru/)
2. Укажите `clientId` и `clientSecret` в `YandexOAuthService.swift`
3. В приложении: Настройки → Аккаунт → OAuth → авторизуйтесь через браузер

## Структура проекта

```
YandexCalendarReminder/
├── Package.swift
└── YandexCalendarReminder/
    ├── App.swift                        # Точка входа
    ├── AppDelegate.swift                # Полноэкранные уведомления + snooze
    ├── Info.plist
    ├── Models/
    │   ├── CalendarEvent.swift          # Модель события
    │   └── ReminderSettings.swift       # Настройки (DND, auth, Keychain)
    ├── Services/
    │   ├── KeychainService.swift        # Безопасное хранение паролей
    │   ├── YandexOAuthService.swift     # OAuth 2.0 авторизация
    │   ├── YandexCalDAVService.swift    # CalDAV синхронизация + retry
    │   ├── CalDAVXMLParser.swift        # XML парсер (XMLParser)
    │   ├── ICalParser.swift             # iCal парсер с RRULE и таймзонами
    │   ├── ReminderService.swift        # Напоминания, snooze, DND, кэш
    │   ├── NetworkMonitor.swift         # Мониторинг сети + retry
    │   └── EventCache.swift            # Оффлайн кэш событий
    └── Views/
        ├── MenuBarView.swift            # Менюбар с группировкой по дням
        ├── SettingsView.swift           # Настройки (OAuth, DND, интервалы)
        └── AddEventView.swift           # Ручное добавление событий
```
