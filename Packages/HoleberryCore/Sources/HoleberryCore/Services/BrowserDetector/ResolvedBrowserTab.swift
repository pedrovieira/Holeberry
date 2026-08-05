/// The result of resolving the current browser tab state.
public enum ResolvedBrowserTab: Equatable {
  case disabled
  case noBrowser
  case permissionNeeded(Browser)
  case permissionDenied(Browser)
  case noURL(Browser)
  case url(Browser, String)

  public var browser: Browser? {
    switch self {
    case .permissionNeeded(let browser): return browser
    case .permissionDenied(let browser): return browser
    case .noURL(let browser): return browser
    case .url(let browser, _): return browser
    case .disabled, .noBrowser: return nil
    }
  }
}
