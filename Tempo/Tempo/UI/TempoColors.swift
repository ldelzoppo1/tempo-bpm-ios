import SwiftUI

extension Color {
    // Background
    static let tempoBg     = Color(red: 9/255,   green: 14/255,  blue: 28/255)   // #090E1C — midnight navy
    static let tempoPanel  = Color(red: 19/255,  green: 27/255,  blue: 46/255)   // #131B2E — dark panel (solid, no material)
    static let tempoBorder = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.11)  // glass edge
    static let tempoDark   = Color(red: 12/255,  green: 18/255,  blue: 32/255)   // #0C1220 — inner darker surface
    // Accents
    static let tempoAccent = Color(red: 255/255, green: 140/255, blue: 53/255)   // #FF8C35 — warm amber-orange
    static let tempoGreen  = Color(red: 48/255,  green: 209/255, blue: 88/255)   // #30D158 — Apple system green
    static let tempoAmber  = Color(red: 255/255, green: 184/255, blue: 48/255)   // #FFB830 — golden amber
    // Text
    static let tempoText   = Color(red: 240/255, green: 242/255, blue: 255/255)  // #F0F2FF — cool white
    static let tempoMuted  = Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.38)  // subdued glass text
    // Gradient stops (used by ContentView background)
    static let tempoGradTop    = Color(red: 23/255,  green: 32/255,  blue: 62/255)
    static let tempoGradMid    = Color(red: 10/255,  green: 16/255,  blue: 32/255)
    static let tempoGradBottom = Color(red: 5/255,   green: 8/255,   blue: 16/255)
}
