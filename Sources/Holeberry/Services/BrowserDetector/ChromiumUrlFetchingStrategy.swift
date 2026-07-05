import Foundation

final class ChromiumUrlFetchingStrategy: AppleScriptUrlFetchingStrategy {
  init(appName: String) {
    super.init(appName: appName, scriptCommand: "get URL of active tab of front window")
  }
}
