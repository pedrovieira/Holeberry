import Foundation
import Testing

@testable import HoleberryCore

@Suite("BlockingStatus")
struct BlockingStatusTests {
  @Test func equality() {
    #expect(BlockingStatus.enabled == BlockingStatus.enabled)
    #expect(BlockingStatus.disabled(remainingSeconds: nil) == BlockingStatus.disabled(remainingSeconds: nil))
    #expect(BlockingStatus.disabled(remainingSeconds: 30) == BlockingStatus.disabled(remainingSeconds: 30))
    #expect(BlockingStatus.enabled != BlockingStatus.disabled(remainingSeconds: nil))
    #expect(BlockingStatus.disabled(remainingSeconds: 10) != BlockingStatus.disabled(remainingSeconds: 30))
  }
}
