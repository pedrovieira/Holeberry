import Foundation

final class SafariUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  init(appName: String) {
    super.init(appName: appName, scriptCommand: "get URL of front document")
  }
}
