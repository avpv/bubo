import Foundation

// MARK: - Task List Expansion

/// Three-state disclosure for the Tasks card.
///
/// - `.collapsed`: только хедер, список полностью скрыт.
/// - `.compact`: максимум 4 строки видны, остальные — внутренним скроллом.
///   Сохраняет место под таймлайн ниже карточки.
/// - `.expanded`: полностью раскрыт до `fullyExpandedMaxHeight`, пользователь
///   осознанно жертвует видимостью таймлайна ради полного списка.
///
/// Birman: один триггер (шеврон) переключает состояния — без дублирующих
/// кнопок «Show more» / «Show fewer».
enum TaskListExpansion: Equatable, Hashable {
    case collapsed
    case compact
    case expanded

    /// Next state in the round-trip cycle.
    var next: TaskListExpansion {
        switch self {
        case .collapsed: return .compact
        case .compact:   return .expanded
        case .expanded:  return .collapsed
        }
    }

    /// SF Symbol for the disclosure chevron.
    /// One arrow = стандартное раскрытие; двойная стрелка = «раскрыто
    /// полностью».
    var iconName: String {
        switch self {
        case .collapsed: return "chevron.right"
        case .compact:   return "chevron.down"
        case .expanded:  return "chevron.down.2"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .collapsed: return "Show tasks"
        case .compact:   return "Show all tasks"
        case .expanded:  return "Hide tasks"
        }
    }
}
