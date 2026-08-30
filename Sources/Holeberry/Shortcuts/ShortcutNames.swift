import HoleberryCore
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let disableIndefinitely = Self("disableIndefinitely")
  static let disable10s = Self("disable10s")
  static let disable30s = Self("disable30s")
  static let disable5m = Self("disable5m")
  static let disableCustom = Self("disableCustom")
  static let reEnableBlocking = Self("reEnableBlocking")
  static let unblockCurrentTab = Self("unblockCurrentTab")
  static let updateGravity = Self("updateGravity")

  /// The shortcut name bound to a stored duration entry.
  ///
  /// The three default entries keep their legacy names so existing users'
  /// bindings survive the migration to configurable durations. Custom
  /// entries get a name derived from their stable id.
  static func durationShortcutName(for entry: UnblockDurationEntry) -> KeyboardShortcuts.Name {
    switch entry.id {
    case UnblockDurationEntry.default10sID: return .disable10s
    case UnblockDurationEntry.default30sID: return .disable30s
    case UnblockDurationEntry.default5mID: return .disable5m
    default: return Self("unblockDuration-\(entry.id.uuidString)")
    }
  }
}
