import Foundation

extension Decimal {
    var dashboardText: String {
        let number = NSDecimalNumber(decimal: self)
        return Self.dashboardFormatter.string(from: number) ?? description
    }

    var percentText: String {
        let sign = self > 0 ? "+" : self < 0 ? "-" : ""
        let absolute = self < 0 ? -self : self
        let number = NSDecimalNumber(decimal: absolute)
        return "\(sign)\(Self.percentFormatter.string(from: number) ?? description)%"
    }

    var chartDouble: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }

    private static let dashboardFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        return formatter
    }()
}

extension Date {
    var shortDashboardTime: String {
        Self.shortDashboardTimeFormatter.string(from: self)
    }

    var dashboardDateTime: String {
        Self.dashboardDateTimeFormatter.string(from: self)
    }

    private static let shortDashboardTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dashboardDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()
}
