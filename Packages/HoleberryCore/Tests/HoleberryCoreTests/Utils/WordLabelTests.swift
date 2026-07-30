import Foundation
import Testing

@testable import HoleberryCore

@Suite("WordLabel")
struct WordLabelTests {
  @Test("generates hyphenated by default")
  func generateDefaultStyle() {
    let label = WordLabel.generate()
    #expect(label.contains("-"))
    #expect(!label.contains("_"))
    #expect(!label.contains(" "))
    #expect(label.first?.isLowercase ?? false)
  }

  @Test("generates camelCase")
  func generateCamelCase() {
    let label = WordLabel.generate(style: .camelCase)
    #expect(!label.contains("-"))
    #expect(!label.contains("_"))
    #expect(!label.contains(" "))
    #expect(label.first?.isLowercase ?? false)
  }

  @Test("generates snake_case")
  func generateSnakeCase() {
    let label = WordLabel.generate(style: .snakeCase)
    #expect(label.contains("_"))
    #expect(!label.contains("-"))
    #expect(!label.contains(" "))
  }

  @Test("generates Spaced")
  func generateSpaced() {
    let label = WordLabel.generate(style: .spaced)
    #expect(label.contains(" "))
    #expect(!label.contains("-"))
    #expect(!label.contains("_"))
    let words = label.components(separatedBy: " ")
    #expect(words.count == 2)
    #expect(words[0].first?.isUppercase ?? false)
  }

  @Test("generates unique labels")
  func generateUnique() {
    let labels = WordLabel.generateUnique(count: 5)
    #expect(labels.count == 5)
    #expect(Set(labels).count == 5)
  }

  @Test("generateUnique returns count distinct labels")
  func generateUniqueDistinct() {
    let count = 10
    let labels = WordLabel.generateUnique(count: count)
    #expect(labels.count == count)
  }

  @Test("all generated labels are non-empty")
  func allLabelsNonEmpty() {
    for _ in 0..<100 {
      let label = WordLabel.generate()
      #expect(!label.isEmpty)
    }
  }
}
