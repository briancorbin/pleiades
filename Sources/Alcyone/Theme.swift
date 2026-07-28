import SwiftUI

/// Wilderness-trim palette: anodized copper on near-black.
enum Theme {
    static let background = Color(red: 0.05, green: 0.055, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.10, blue: 0.125)
    static let track = Color.white.opacity(0.08)
    static let copper = Color(red: 0.85, green: 0.55, blue: 0.28)
    static let copperDim = Color(red: 0.55, green: 0.36, blue: 0.19)
    static let redline = Color(red: 0.95, green: 0.30, blue: 0.22)
    static let text = Color.white.opacity(0.92)
    static let textDim = Color.white.opacity(0.45)
}
