import Foundation

/// The three outcomes of querying the Automation permission.
public enum AutomationPermission {
  case allowed
  case denied
  case notDetermined
}

/// Abstracts the Automation permission check so it can be mocked in tests.
public protocol PermissionChecker {
  /// Queries or requests the Automation permission for a target bundle.
  /// - Returns: `.allowed`, `.denied`, or `.notDetermined`.
  func checkPermission(for bundleID: String, askUserIfNeeded: Bool) -> AutomationPermission
}
