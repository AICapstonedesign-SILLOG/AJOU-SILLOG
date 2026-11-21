import Foundation

public enum HourlyTime {
    /// Seconds worked in each hour of the day (0 to 23) over the last `days` days, splitting sessions at hour boundaries.
    /// Args: sessions as (start, end) Unix seconds, now, days, calendar.
    /// Returns: 24 values, index = hour of day.
    /// Raises: none.
    public static func seconds(_ sessions: [(Double, Double)], now: Date = Date(), days: Int = 14, calendar: Calendar = .current) -> [Double] {
        let since = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: now))!.timeIntervalSince1970
        var out = [Double](repeating: 0, count: 24)
        for (start, end) in sessions where end > since && end > start {
            var t = max(start, since)
            while t < end {
                let date = Date(timeIntervalSince1970: t)
                let next = min(end, calendar.dateInterval(of: .hour, for: date)!.end.timeIntervalSince1970)
                out[calendar.component(.hour, from: date)] += next - t
                t = next
            }
        }
        return out
    }
}
