import Foundation

/// Locale-aware, WhatsApp-style chat timestamps. The formatting follows the
/// app's language automatically — with the phone set to Portuguese (Brazil)
/// dates render as "12/08/2026, 14:30" (day/month/year, 24h), while English
/// renders as "Aug 12, 2026, 2:30 PM".
extension Date {
    /// Bubble timestamp: today -> time only; otherwise -> date + time.
    func chatBubbleTimestamp() -> String {
        if Calendar.current.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        return formatted(.dateTime.day().month().year().hour().minute())
    }

    /// Conversation-list timestamp: today -> time only; otherwise -> full date.
    func chatListTimestamp() -> String {
        if Calendar.current.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        return formatted(.dateTime.day().month().year())
    }
}
