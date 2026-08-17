import Foundation

// The "Registration date" row on a user's profile - roughly when the account was created.
// Port of desktop's Lumina::RegistrationDate (lumina/lumina_registration_date.{h,cpp}),
// which itself transcribes Android's ProfileActivity.java REG_ANCHOR_IDS/REG_ANCHOR_DATES
// (lines 10464-10516 there). Kept deliberately framework-agnostic (Foundation only, no
// TelegramCore peer types) so it is easy to unit-reason about and so PeerInfoProfileItems.swift
// stays the only place that has to know which TelegramCore fields feed it.
//
// TWO SOURCES, IN THIS ORDER, AND THEY ARE NOT THE SAME KIND OF FACT.
//
// 1. The server. Telegram sometimes sends a registration month back with peerSettings
//    (PeerStatusSettings.registrationDate in TelegramCore, populated mainly for peers you are
//    not a contact of yet). It is authoritative when present, so it wins, and it is shown
//    plain - no leading "~". Its exact string shape from the API is not independently
//    reverified in this change; it is rendered as-is rather than reparsed, so a display
//    change on Telegram's side can never make this feature show something fabricated.
//
// 2. The client-side estimate, computed here, which is what Android has and all it has.
//    Telegram user ids are handed out in roughly increasing order, so an id can be
//    interpolated against a table of (id, date) anchors into an approximate creation date.
//    This is a heuristic, not a fact - off by weeks near the anchors and by more between
//    them - so it is always rendered with a leading "~" (LuminaRegistrationApproxPrefix).
//
// Nothing here calls the server. Source 1 is a value that already arrived for other reasons;
// source 2 is pure arithmetic on the peer id.
public enum LuminaRegistrationDate {
    public struct Anchor {
        public let id: UInt64
        // Unix timestamp, midnight UTC.
        public let date: Int64

        public init(id: UInt64, date: Int64) {
            self.id = id
            self.date = date
        }
    }

    // Transcribed from ProfileActivity.java:10464-10484 / desktop's lumina_registration_date.cpp,
    // pairwise rather than as two parallel arrays so the two values can never silently drift
    // out of alignment by one entry. Ids sorted ascending - estimatedRegistrationDate(userId:)
    // binary-searches them. The tail entries beyond the highest observed id are Android's own
    // extrapolation, kept as-is so all three clients estimate the same date for the same account.
    public static let anchors: [Anchor] = [
        Anchor(id: 1000000, date: 1380326400),
        Anchor(id: 2768409, date: 1383264000),
        Anchor(id: 7679610, date: 1388448000),
        Anchor(id: 11538514, date: 1391212800),
        Anchor(id: 15835244, date: 1392940800),
        Anchor(id: 23646077, date: 1393459200),
        Anchor(id: 38015510, date: 1393632000),
        Anchor(id: 44634663, date: 1399334400),
        Anchor(id: 46145305, date: 1400198400),
        Anchor(id: 54845238, date: 1411257600),
        Anchor(id: 63263518, date: 1414454400),
        Anchor(id: 101260938, date: 1425600000),
        Anchor(id: 103151531, date: 1433376000),
        Anchor(id: 109393468, date: 1439683200),
        Anchor(id: 112594714, date: 1444176000),
        Anchor(id: 116812045, date: 1448323200),
        Anchor(id: 122600695, date: 1450483200),
        Anchor(id: 124872445, date: 1453248000),
        Anchor(id: 130029930, date: 1457481600),
        Anchor(id: 132670343, date: 1461283200),
        Anchor(id: 141733941, date: 1465344000),
        Anchor(id: 152253017, date: 1466121600),
        Anchor(id: 157242073, date: 1471046400),
        Anchor(id: 171295414, date: 1474156800),
        Anchor(id: 188758258, date: 1476835200),
        Anchor(id: 191317690, date: 1477267200),
        Anchor(id: 199570902, date: 1481932800),
        Anchor(id: 229882272, date: 1493856000),
        Anchor(id: 234462946, date: 1499472000),
        Anchor(id: 253685473, date: 1504137600),
        Anchor(id: 293169835, date: 1508025600),
        Anchor(id: 315690368, date: 1526342400),
        Anchor(id: 342781860, date: 1529625600),
        Anchor(id: 352940995, date: 1532563200),
        Anchor(id: 369669043, date: 1538006400),
        Anchor(id: 400169472, date: 1542326400),
        Anchor(id: 616816630, date: 1548720000),
        Anchor(id: 700000000, date: 1556668800),
        Anchor(id: 800000000, date: 1571184000),
        Anchor(id: 900000000, date: 1585699200),
        Anchor(id: 1000000000, date: 1600214400),
        Anchor(id: 1200000000, date: 1614556800),
        Anchor(id: 1400000000, date: 1625097600),
        Anchor(id: 1600000000, date: 1633046400),
        Anchor(id: 1800000000, date: 1643673600),
        Anchor(id: 2000000000, date: 1656633600),
        Anchor(id: 3000000000, date: 1690848000),
        Anchor(id: 4000000000, date: 1719792000),
        Anchor(id: 5000000000, date: 1748736000),
        Anchor(id: 6000000000, date: 1777680000),
        Anchor(id: 7000000000, date: 1806624000),
    ]

    // Source (2): the interpolated estimate for a bare user id, as a unix timestamp. nil for
    // id 0. Clamped to the first / last anchor outside the table's range, exactly as
    // Android/desktop clamp.
    public static func estimatedRegistrationDate(userId: Int64) -> Date? {
        guard userId > 0 else {
            return nil
        }
        let id = UInt64(userId)
        let count = anchors.count
        if id <= anchors[0].id {
            return Date(timeIntervalSince1970: TimeInterval(anchors[0].date))
        } else if id >= anchors[count - 1].id {
            return Date(timeIntervalSince1970: TimeInterval(anchors[count - 1].date))
        }
        var low = 0
        var high = count - 1
        while high - low > 1 {
            let middle = low + (high - low) / 2
            if anchors[middle].id <= id {
                low = middle
            } else {
                high = middle
            }
        }
        let span = anchors[high].id - anchors[low].id
        if span == 0 {
            return Date(timeIntervalSince1970: TimeInterval(anchors[low].date))
        }
        let shift = Double(anchors[high].date - anchors[low].date) * Double(id - anchors[low].id) / Double(span)
        return Date(timeIntervalSince1970: TimeInterval(anchors[low].date) + shift)
    }

    // Month (0-based, like stringForMonth(strings:month:ofYear:) in TelegramStringFormatting
    // expects) and year-since-1900 for an estimated date, read in UTC - the anchors are
    // midnight UTC, so reading them back in local time could move an exact anchor hit to the
    // previous month west of Greenwich, a whole month of error in a value this row already
    // only claims to the month. PeerInfoProfileItems.swift combines this with stringForMonth
    // and its own presentationData.strings so the row is localized like the rest of the
    // profile screen, instead of this framework-agnostic file hardcoding English.
    public static func estimatedMonthAndYear(userId: Int64) -> (month: Int32, year: Int32)? {
        guard let date = estimatedRegistrationDate(userId: userId) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.month, .year], from: date)
        guard let month = components.month, let year = components.year else {
            return nil
        }
        // stringForMonth's `month` is 0-based (0 = January) and `year` is an offset from 1900.
        return (Int32(month - 1), Int32(year - 1900))
    }
}
