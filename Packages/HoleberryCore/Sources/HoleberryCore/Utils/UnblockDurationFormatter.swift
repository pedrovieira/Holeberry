import Foundation

/// Formats seconds as a human-readable menu label, largest unit first,
/// omitting zero parts ("10 seconds", "5 minutes", "1 hour 30 minutes").
public enum UnblockDurationFormatter {
  public static func string(from seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60

    var parts: [String] = []
    if hours > 0 { parts.append(unit(hours, singular: "hour")) }
    if minutes > 0 { parts.append(unit(minutes, singular: "minute")) }
    if secs > 0 || parts.isEmpty { parts.append(unit(secs, singular: "second")) }
    return parts.joined(separator: " ")
  }

  private static func unit(_ value: Int, singular: String) -> String {
    value == 1 ? "1 \(singular)" : "\(value) \(singular)s"
  }
}
