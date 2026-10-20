import Testing
@testable import Memebooru

struct LocalizationTests {
    @Test func relationDirectionIsPreserved() {
        #expect(localizedRelation(.contains, outgoing: true) == "Содержит")
        #expect(localizedRelation(.contains, outgoing: false) == "Входит в")
        #expect(localizedRelation(.replyTo, outgoing: true) == "Ответ на")
        #expect(localizedRelation(.quote, outgoing: false) == "Цитируется в")
    }
    @Test func russianCounts() {
        #expect(plural(1, "tag") == "1 тег")
        #expect(plural(2, "tag") == "2 тега")
        #expect(plural(5, "tag") == "5 тегов")
        #expect(plural(11, "action") == "11 действий")
        #expect(plural(21, "group") == "21 группа")
        #expect(plural(112, "crop") == "112 фрагментов")
    }
    @Test func historyLabelsDoNotChangeUserText() {
        #expect(localizedHistoryLabel("Committed 1 item") == "Сохранено: 1")
        #expect(localizedHistoryLabel("Discarded 12 items") == "Убрано из входящих: 12")
        #expect(localizedHistoryLabel("Combined 3 pictures") == "Объединено изображений: 3")
        #expect(localizedHistoryLabel("My Committed 1 item picture") == "My Committed 1 item picture")
        #expect(localizedHistoryLabel("Мой комментарий") == "Мой комментарий")
    }
}
