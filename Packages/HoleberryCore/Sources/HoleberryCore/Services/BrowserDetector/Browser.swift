import Foundation

public enum Browser: String, CaseIterable {
  // WebKit
  case safari = "com.apple.Safari"
  case safariTechnologyPreview = "com.apple.SafariTechnologyPreview"
  case orion = "com.kagi.kagimacOS"
  case orionRC = "com.kagi.kagimacOS.RC"
  // Chrome
  case chrome = "com.google.Chrome"
  case chromeBeta = "com.google.Chrome.beta"
  case chromeDev = "com.google.Chrome.dev"
  case chromeCanary = "com.google.Chrome.canary"
  // Edge
  case edge = "com.microsoft.edgemac"
  case edgeBeta = "com.microsoft.edgemac.beta"
  case edgeDev = "com.microsoft.edgemac.dev"
  case edgeCanary = "com.microsoft.edgemac.canary"
  // Brave
  case brave = "com.brave.Browser"
  case braveBeta = "com.brave.Browser.beta"
  case braveNightly = "com.brave.Browser.nightly"
  // Arc
  case arc = "company.thebrowser.Browser"
  // Opera
  case opera = "com.operasoftware.Opera"
  case operaNext = "com.operasoftware.OperaNext"
  case operaDeveloper = "com.operasoftware.OperaDeveloper"
  // Vivaldi
  case vivaldi = "com.vivaldi.Vivaldi"
  case vivaldiSnapshot = "com.vivaldi.Vivaldi.snapshot"
  // Helium
  case helium = "net.imput.helium"
  // Firefox
  case firefox = "org.mozilla.firefox"
  case firefoxDeveloperEdition = "org.mozilla.firefoxdeveloperedition"
  case firefoxNightly = "org.mozilla.nightly"
  // Zen Browser
  case zen = "app.zen-browser.zen"
  // Waterfox
  case waterfox = "net.waterfox.waterfox"

  public var bundleID: String { rawValue }

  public var appName: String {
    switch self {
    case .safari: return "Safari"
    case .safariTechnologyPreview: return "Safari Technology Preview"
    case .orion: return "Orion"
    case .orionRC: return "Orion RC"
    case .chrome: return "Google Chrome"
    case .chromeBeta: return "Google Chrome Beta"
    case .chromeDev: return "Google Chrome Dev"
    case .chromeCanary: return "Google Chrome Canary"
    case .edge: return "Microsoft Edge"
    case .edgeBeta: return "Microsoft Edge Beta"
    case .edgeDev: return "Microsoft Edge Dev"
    case .edgeCanary: return "Microsoft Edge Canary"
    case .brave: return "Brave Browser"
    case .braveBeta: return "Brave Browser Beta"
    case .braveNightly: return "Brave Browser Nightly"
    case .arc: return "Arc"
    case .opera: return "Opera"
    case .operaNext: return "Opera Next"
    case .operaDeveloper: return "Opera Developer"
    case .vivaldi: return "Vivaldi"
    case .vivaldiSnapshot: return "Vivaldi Snapshot"
    case .helium: return "Helium"
    case .firefox: return "Firefox"
    case .firefoxDeveloperEdition: return "Firefox Developer Edition"
    case .firefoxNightly: return "Firefox Nightly"
    case .zen: return "Zen Browser"
    case .waterfox: return "Waterfox"
    }
  }
}
