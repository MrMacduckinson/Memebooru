import Foundation
import MemebooruCore

func localizedRelation(_ kind: Relation.Kind, outgoing: Bool) -> String {
    switch kind {
    case .duplicate: "Дубликат"
    case .variant: "Вариант"
    case .contains: outgoing ? "Содержит" : "Входит в"
    case .replyTo: outgoing ? "Ответ на" : "Ответ"
    case .quote: outgoing ? "Цитирует" : "Цитируется в"
    case .partOf: outgoing ? "Часть подборки" : "Включает"
    }
}

/// Translate built-in history labels at display time; stored history and user text stay intact.
func localizedHistoryLabel(_ label: String) -> String {
    let patterns = [
        (#"^Committed (\d+) items?$"#, "Сохранено: $1"),
        (#"^Commit (\d+) staged$"#, "Сохранить входящие: $1"),
        (#"^Discarded (\d+) items?$"#, "Убрано из входящих: $1"),
        (#"^Discard (\d+) staged$"#, "Убрать входящие: $1"),
        (#"^Deleted (\d+) memes?$"#, "Удалено: $1"),
        (#"^Delete (\d+)$"#, "Удалить: $1"),
        (#"^Combined? (\d+) pictures$"#, "Объединено изображений: $1"),
        (#"^Split into (\d+) pictures$"#, "Разделено на изображения: $1")
    ]
    for (pattern, translated) in patterns where label.range(of: pattern, options: .regularExpression) != nil {
        return label.replacingOccurrences(of: pattern, with: translated, options: .regularExpression)
    }
    return label
}
