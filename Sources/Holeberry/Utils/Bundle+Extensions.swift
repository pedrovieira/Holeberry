import Foundation

extension Bundle {
  var releaseVersionNumber: String? {
    infoDictionary?["CFBundleShortVersionString"] as? String
  }

  var buildVersionNumber: String? {
    infoDictionary?["CFBundleVersion"] as? String
  }
}
