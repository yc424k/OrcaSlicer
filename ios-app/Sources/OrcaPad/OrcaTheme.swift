import SwiftUI

/// OrcaSlicer desktop palette (src/slic3r/GUI/Widgets/StateColor.cpp and
/// Button.cpp), as light/dark dynamic colors.
extension UIColor {
    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        }
    }

    /// Signature Orca green (confirm buttons; brighter variant in dark mode).
    static let orcaAccent = dynamic(light: 0x009688, dark: 0x22BFB0)
    /// Window background (#FFFFFF / #2D2D31).
    static let orcaWindow = dynamic(light: 0xFFFFFF, dark: 0x2D2D31)
    /// Sidebar background (#F8F8F8 / #36363C).
    static let orcaPanel = dynamic(light: 0xF8F8F8, dark: 0x36363C)
    /// Cards / input boxes on panels (#FFFFFF / #3B3B40).
    static let orcaCard = dynamic(light: 0xFFFFFF, dark: 0x3B3B40)
    /// Separator lines (#EEEEEE / #4C4C55).
    static let orcaSeparator = dynamic(light: 0xEEEEEE, dark: 0x4C4C55)
    /// 3D viewport backdrop.
    static let orcaViewport = dynamic(light: 0xEAEDF0, dark: 0x2D2D31)
    /// Print bed plate.
    static let orcaBed = dynamic(light: 0xCECECE, dark: 0x54545B)
}

extension Color {
    static let orcaAccent = Color(UIColor.orcaAccent)
    static let orcaWindow = Color(UIColor.orcaWindow)
    static let orcaPanel = Color(UIColor.orcaPanel)
    static let orcaCard = Color(UIColor.orcaCard)
    static let orcaSeparator = Color(UIColor.orcaSeparator)
}
