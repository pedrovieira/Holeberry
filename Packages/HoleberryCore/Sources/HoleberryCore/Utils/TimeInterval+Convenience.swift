import Foundation

extension TimeInterval {
  static func hours(_ value: Double) -> TimeInterval { value * 3_600 }
  static func days(_ value: Double) -> TimeInterval { value * 86_400 }
}
