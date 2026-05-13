import Foundation

extension Decimal {
    var dashboardText: String {
        let number = NSDecimalNumber(decimal: self)
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        formatter.numberStyle = .decimal
        return formatter.string(from: number) ?? description
    }

    var percentText: String {
        let sign = self > 0 ? "+" : self < 0 ? "-" : ""
        let absolute = self < 0 ? -self : self
        let number = NSDecimalNumber(decimal: absolute)
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.numberStyle = .decimal
        return "\(sign)\(formatter.string(from: number) ?? description)%"
    }

    var chartDouble: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

extension Date {
    var shortDashboardTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: self)
    }

    var dashboardDateTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: self)
    }
}
