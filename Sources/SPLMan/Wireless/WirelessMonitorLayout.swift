import CoreGraphics
import Foundation

/// Places one column per channel side by side: name and battery on top, then the
/// audio and signal strength bars. Text that would not fit a narrow column is
/// left out, while the bars always stay.
struct WirelessMonitorLayout: Equatable {
    struct Column: Equatable {
        var channel: WirelessChannel
        var frame: CGRect
        var audioBar: CGRect
        var rfBar: CGRect
        var battery: CGRect
        var showsName: Bool
        var showsBarLabels: Bool
        var showsBatteryMinutes: Bool
    }

    private static let edgeInset: CGFloat = 4
    private static let columnGap: CGFloat = 8
    private static let largestColumnWidth: CGFloat = 120
    private static let barGap: CGFloat = 2
    /// The audio level is the main reading, so it gets the wider bar.
    private static let audioBarShare: CGFloat = 0.62
    private static let headerHeight: CGFloat = 30
    private static let footerHeight: CGFloat = 13
    private static let batteryTop: CGFloat = 17
    private static let batteryHeight: CGFloat = 8
    private static let smallestWidthForName: CGFloat = 24
    private static let smallestWidthForBarLabels: CGFloat = 36
    private static let smallestWidthForBatteryMinutes: CGFloat = 90
    /// Room for "999 min" beside the battery segments.
    private static let batteryMinutesWidth: CGFloat = 44

    var columns: [Column]

    static func compute(channels: [WirelessChannel], size: CGSize) -> WirelessMonitorLayout {
        guard !channels.isEmpty, size.width > 0, size.height > 0 else {
            return WirelessMonitorLayout(columns: [])
        }
        let count = CGFloat(channels.count)
        let available = size.width - 2 * edgeInset - (count - 1) * columnGap
        let width = min(largestColumnWidth, max(1, available / count))
        let barTop = min(headerHeight, size.height)
        let barHeight = max(0, size.height - headerHeight - footerHeight)
        let gap = width > 2 * barGap ? barGap : 0
        let barArea = width - gap

        var columns: [Column] = []
        for (index, channel) in channels.enumerated() {
            let x = edgeInset + CGFloat(index) * (width + columnGap)
            let showsMinutes = width >= smallestWidthForBatteryMinutes
            columns.append(Column(
                channel: channel,
                frame: CGRect(x: x, y: 0, width: width, height: size.height),
                audioBar: CGRect(
                    x: x,
                    y: barTop,
                    width: barArea * audioBarShare,
                    height: barHeight
                ),
                rfBar: CGRect(
                    x: x + barArea * audioBarShare + gap,
                    y: barTop,
                    width: barArea * (1 - audioBarShare),
                    height: barHeight
                ),
                battery: CGRect(
                    x: x,
                    y: batteryTop,
                    width: max(0, width - (showsMinutes ? batteryMinutesWidth : 0)),
                    height: batteryHeight
                ),
                showsName: width >= smallestWidthForName,
                showsBarLabels: width >= smallestWidthForBarLabels,
                showsBatteryMinutes: showsMinutes
            ))
        }
        return WirelessMonitorLayout(columns: columns)
    }
}
