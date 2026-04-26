import Foundation

// MARK: - Task List Expansion

/// Two-state disclosure for the Tasks card.
///
/// - `.collapsed`: только хедер, список полностью скрыт.
/// - `.compact`: показан список с верхним пределом (~4 строки), остальные —
///   внутренним скроллом. Сохраняет место под таймлайн ниже карточки.
///
/// «Полное раскрытие без таймлайна» больше не живёт здесь — оно превратилось
/// в отдельный полноэкранный вью (`SprintView`), который пушится в
/// навигационный стек popover'а через `onEnterSprint`. Один шеврон отвечает
/// только за «есть список / нет списка» — без третьего загадочного состояния.
///
/// Birman: один шеврон — один смысл; полноэкранное представление — отдельный
/// аффорданс рядом, не третий клик той же кнопки.
///
/// `.expanded` остаётся внутренним состоянием, в которое BacklogView временно
/// переключается на время drag'а, чтобы все строки-цели реордера были видны
/// сразу. Через UI пользователь в это состояние не попадает.
enum TaskListExpansion: Equatable, Hashable {
    case collapsed
    case compact
    /// Internal-only: используется на время drag'а в `BacklogView`. Через
    /// шеврон не достижимо.
    case expanded

    /// Next state in the round-trip cycle. `.expanded` сюда не входит — оно
    /// программно ставится во время drag'а и снимается обратно по drop'у.
    var next: TaskListExpansion {
        switch self {
        case .collapsed: return .compact
        case .compact:   return .collapsed
        case .expanded:  return .collapsed
        }
    }

    /// SF Symbol for the disclosure chevron. `.expanded` визуально совпадает
    /// с `.compact` — пользователь шеврон в этом состоянии не видит, но
    /// switch обязан быть исчерпывающим.
    var iconName: String {
        switch self {
        case .collapsed:        return "chevron.right"
        case .compact, .expanded: return "chevron.down"
        }
    }

    var accessibilityHint: String {
        switch self {
        case .collapsed:        return "Show tasks"
        case .compact, .expanded: return "Hide tasks"
        }
    }
}
