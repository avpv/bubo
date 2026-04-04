# Bubo — Architecture

## Overview

Bubo — нативное macOS-приложение (Swift/SwiftUI), которое живет в menu bar и помогает управлять встречами и фокус-временем. Включает полноэкранные алерты, Pomodoro-сессии и AI-оптимизацию расписания.

**Стек:** Swift 5.9+, SwiftUI, SwiftData, EventKit, macOS 14+ (Sonoma)
**Прокси:** TypeScript / Cloudflare Workers

---

## Структура проекта

```
bubo/
├── Bubo/                  # Основное приложение (Swift)
│   ├── App.swift          # Точка входа SwiftUI
│   ├── AppDelegate.swift  # macOS-интеграция (окна, уведомления)
│   ├── Models/            # Модели данных и персистентность
│   ├── Services/          # Бизнес-логика
│   ├── Views/             # UI-компоненты
│   ├── ViewModels/        # Логика представлений
│   ├── Optimizer/         # Генетический алгоритм оптимизации
│   ├── Skins/             # Темы оформления (JSON)
│   ├── Utils/             # Утилиты
│   └── Resources/         # Иконки и ассеты
├── Tests/                 # Юнит-тесты (GA, рецепты)
├── proxy/                 # Cloudflare Worker (TypeScript)
├── docs/                  # Документация
├── Casks/                 # Homebrew Cask
├── packaging/             # Скрипты дистрибуции
├── scripts/               # Скрипты сборки
└── Package.swift          # Swift Package manifest
```

---

## Слои архитектуры

### 1. Models (`Bubo/Models/`)

| Файл | Назначение |
|---|---|
| `CalendarEvent.swift` | Основная модель события — title, dates, location, recurrence, meeting links (Zoom/Meet/Teams), Pomodoro-сегменты, цветовые теги |
| `ReminderSettings.swift` | Глобальные настройки (`@Observable`, UserDefaults) — интервалы напоминаний, календари, скины, обои, бейдж, мировые часы |
| `RecurrenceRule.swift` | RFC 5545 правила повторения — daily/weekly/monthly/yearly, end conditions, Pomodoro-режим |
| `PersistedEvent.swift` | SwiftData-модели: `PersistedLocalEvent`, `PersistedCachedEvent`, `PersistedExcludedOccurrence`, `PersistedReminderOverride` |
| `WallpaperDefinition.swift` | Каталог визуальных тем для полноэкранных алертов |

### 2. Services (`Bubo/Services/`)

| Сервис | Роль |
|---|---|
| **ReminderService** | Ядро приложения. Синхронизация с Apple Calendar (EventKit), управление таймерами напоминаний, полноэкранные алерты, кэш событий, бейджи. ~22.5KB |
| **AgentService** | LLM-интеграция. Два режима: built-in (через proxy) и own-key (прямой доступ к DeepSeek API). Rate limiting, хранение ключей в Keychain |
| **OptimizerService** | Оркестрация оптимизации расписания. Обёртка над генетическим алгоритмом, рецепты, сценарии, undo |
| **AppleCalendarService** | EventKit-интеграция: синхронизация системных календарей (iCloud, Google, Exchange, CalDAV) |
| **EventCache** | Офлайн-кэш событий |
| **NetworkMonitor** | Мониторинг сетевого подключения |
| **Keychain** | Обёртка macOS Keychain для API-ключей |

### 3. Views (`Bubo/Views/`)

**Основные экраны:**

- **MenuBarView** — главный попровер (360x600): таймлайн дня, события, быстрое создание
- **FullScreenAlertView** — полноэкранное напоминание с обратным отсчётом и кастомным фоном
- **TimerScreenView** — Pomodoro-таймер с кольцевым прогрессом (плавающее окно)
- **AddEventView** — создание события с датами, повторениями, Pomodoro-настройками, цветовыми тегами
- **SettingsView** — вкладки: General, Calendars, Reminders, Skins, Optimizer, AI, World Clock
- **OptimizerView** — интерфейс оптимизации расписания
- **AgentInputView** — ввод на естественном языке для AI

**Компоненты:**

- `EventRowView` — строка события с действиями
- `DaySectionView` — заголовок дня и контейнер событий
- `DateTimePickerPills` — пиллы выбора даты/времени
- `WorldClockStripView` — мировые часы
- `DesignSystem.swift` — централизованные дизайн-токены (23KB)

### 4. Optimizer (`Bubo/Optimizer/`)

Генетический алгоритм оптимизации расписания:

```
Optimizer/
├── GACore/
│   ├── GeneticAlgorithm.swift   # Основной движок GA
│   ├── Chromosome.swift          # Представление расписания (ген = размещение события)
│   ├── Population.swift          # Управление популяцией
│   ├── Selection.swift           # Турнирная/рулеточная селекция
│   ├── Crossover.swift           # Одно- и многоточечный кроссовер
│   └── Mutation.swift            # Операторы мутации
├── Constraints/
│   ├── ConstraintEngine.swift    # Движок жёстких ограничений
│   └── Constraint.swift          # Базовые типы ограничений
├── Fitness/Objectives/           # Оценка фитнеса (spacing, focus, energy, meetings)
├── Recipes/
│   ├── ScheduleRecipe.swift      # Data-driven рецепт (10 измерений)
│   ├── RecipeCatalog.swift       # Каталог встроенных рецептов
│   ├── RecipeExecutor.swift      # Применение рецептов к расписанию
│   ├── RecipeMonitor.swift       # Авто-триггеры и контекстные предложения
│   ├── RecipeUsageTracker.swift  # Аналитика использования
│   └── LLMRecipeBridge.swift     # Мост: естественный язык → рецепт
├── Scenarios/
│   └── ScenarioGenerator.swift   # Генерация нескольких вариантов расписания
├── Learning/
│   └── PreferenceLearner.swift   # Обучение на основе обратной связи
└── Reoptimizer/
    └── IncrementalReoptimizer.swift  # Быстрая ре-оптимизация при изменениях
```

**Ключевые концепции:**
- **Chromosome** — кодирует расписание как набор генов (позиция каждого события)
- **Recipe** — декларативная конфигурация оптимизации (JSON-сериализуемая, 10 параметров)
- **Scenario** — конкретный вариант оптимизированного расписания
- **Fitness** — многокритериальная оценка: spacing, focus blocks, meeting distribution, energy

### 5. Skins (`Bubo/Skins/`)

Система тем:
- 10+ встроенных тем (Arctic, Ocean, Midnight, RoseGold, Classic, Sierra, Lavender, Sage и др.)
- JSON-формат с валидацией по схеме (`buboskin.schema.json`)
- Параметры: акцентный цвет, градиент фона, прозрачность, блюр, стили кнопок

---

## Proxy (`proxy/`)

Cloudflare Worker на TypeScript — защищает API-ключ DeepSeek.

**Эндпоинт:** `POST /v1/agent/recipe`

- Хранит API-ключ серверно (не в бинарнике)
- Rate limiting: 20 запросов/устройство/день (через Cloudflare KV)
- Проксирует запросы к `https://api.deepseek.com/chat/completions`
- Возвращает заголовки: `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`

---

## Персистентность

| Хранилище | Данные |
|---|---|
| **SwiftData** | Локальные события, кэш календаря, исключения повторений, переопределения напоминаний |
| **UserDefaults** | Настройки, режим агента, цветовые метки, device ID |
| **Keychain** | API-ключ пользователя (own-key режим) |
| **EventKit** | Системные календари (iCloud, Google, Exchange) |

---

## Паттерны проектирования

1. **Observable Pattern** — `@Observable` макрос для реактивного состояния (ReminderService, OptimizerService, AgentService)
2. **Menu Bar Accessory App** — `LSUIElement=true`, без Dock-иконки, только menu bar
3. **Notification-Driven** — взаимодействие через `NotificationCenter` (алерты, таймеры, snooze, настройки)
4. **Layered Architecture** — Views → ViewModels → Services → Models
5. **Genetic Algorithm** — популяционная оптимизация с мульти-критериальным фитнесом
6. **Recipe System** — data-driven конфигурации без изменения кода
7. **Preference Learning** — обучение на обратной связи пользователя

---

## Безопасность

- API-ключ DeepSeek хранится серверно в Cloudflare Worker
- Пользовательский ключ — в macOS Keychain (не в UserDefaults)
- Per-device rate limiting (20 req/day)
- macOS Sandbox с доступом только к календарю
- Локальная обработка данных (без внешнего трекинга)
