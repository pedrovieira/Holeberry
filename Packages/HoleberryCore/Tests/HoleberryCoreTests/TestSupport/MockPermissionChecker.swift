import Foundation

@testable import HoleberryCore

final class MockPermissionChecker: PermissionChecker {
  var stubbedPermission: AutomationPermission = .allowed
  private(set) var checkPermissionCallCount = 0
  private(set) var lastBundleID: String?
  private(set) var lastAskUserIfNeeded: Bool?

  func checkPermission(for bundleID: String, askUserIfNeeded: Bool) -> AutomationPermission {
    checkPermissionCallCount += 1
    lastBundleID = bundleID
    lastAskUserIfNeeded = askUserIfNeeded
    return stubbedPermission
  }
}
