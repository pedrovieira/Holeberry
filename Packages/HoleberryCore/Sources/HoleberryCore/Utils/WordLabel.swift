import Foundation

/// Generates random human-readable labels like "regal-sound" or "swift-oak".
///
/// Usage:
///   let label = WordLabel.generate()                    // "silent-reef"
///   let camel = WordLabel.generate(style: .camelCase)   // "silentReef"
///   let batch = WordLabel.generateUnique(count: 5)      // 5 distinct labels
public enum WordLabel {
  public enum Style {
    case hyphenated  // "silent-reef"
    case camelCase  // "silentReef"
    case snakeCase  // "silent_reef"
    case spaced  // "Silent Reef"
  }

  // MARK: - Public API

  public static func generate(style: Style = .hyphenated) -> String {
    let adj = adjectives.randomElement() ?? "silent"
    let noun = nouns.randomElement() ?? "reef"
    return format(adj, noun, style: style)
  }

  /// Returns `count` guaranteed-unique labels. Falls back gracefully if the
  /// word-list space is exhausted (80 × 84 = 6,720 possible combinations).
  public static func generateUnique(count: Int, style: Style = .hyphenated) -> [String] {
    precondition(
      count <= adjectives.count * nouns.count,
      "Requested more unique labels than the word lists can produce.")
    var seen = Set<String>()
    var tries = 0
    while seen.count < count {
      seen.insert(generate(style: style))
      tries += 1
      if tries > count * 20 { break }  // safety valve
    }
    return Array(seen)
  }

  // MARK: - Formatting

  private static func format(_ adj: String, _ noun: String, style: Style) -> String {
    switch style {
    case .hyphenated: return "\(adj)-\(noun)"
    case .snakeCase: return "\(adj)_\(noun)"
    case .camelCase: return "\(adj)\(noun.capitalized)"
    case .spaced: return "\(adj.capitalized) \(noun.capitalized)"
    }
  }

  // MARK: - Word Lists (80 adjectives × 89 nouns = 7,120 combinations)

  private static let adjectives: [String] = [
    "amber",
    "ancient",
    "arctic",
    "bold",
    "brave",
    "bright",
    "calm",
    "clever",
    "cool",
    "coral",
    "crimson",
    "daring",
    "dawn",
    "deft",
    "dusty",
    "eager",
    "early",
    "fancy",
    "fierce",
    "fleet",
    "frozen",
    "gentle",
    "gilded",
    "grand",
    "green",
    "happy",
    "hidden",
    "hollow",
    "icy",
    "idle",
    "iron",
    "jade",
    "keen",
    "kind",
    "late",
    "light",
    "lively",
    "lone",
    "lucky",
    "misty",
    "muted",
    "narrow",
    "noble",
    "north",
    "old",
    "pale",
    "polar",
    "prime",
    "proud",
    "pure",
    "quick",
    "quiet",
    "regal",
    "rosy",
    "rusty",
    "sage",
    "sharp",
    "silent",
    "silver",
    "sleek",
    "slim",
    "slow",
    "small",
    "solar",
    "solid",
    "still",
    "stone",
    "stormy",
    "strong",
    "sunny",
    "swift",
    "teal",
    "tiny",
    "vast",
    "vivid",
    "warm",
    "wild",
    "wise",
    "wry",
    "young"
  ]

  private static let nouns: [String] = [
    "anchor",
    "arc",
    "ash",
    "bark",
    "beam",
    "bell",
    "bird",
    "blade",
    "block",
    "bloom",
    "bolt",
    "brook",
    "cache",
    "cedar",
    "cliff",
    "cloud",
    "coast",
    "comet",
    "coral",
    "crest",
    "crow",
    "dawn",
    "dns",
    "dune",
    "echo",
    "ember",
    "fern",
    "field",
    "flame",
    "flint",
    "fog",
    "forest",
    "frost",
    "gale",
    "gate",
    "glen",
    "grove",
    "gulf",
    "hawk",
    "helm",
    "hill",
    "home",
    "horn",
    "hound",
    "instance",
    "isle",
    "keep",
    "lake",
    "lark",
    "leaf",
    "ledge",
    "light",
    "lore",
    "marsh",
    "mist",
    "moon",
    "moss",
    "mount",
    "note",
    "oak",
    "path",
    "peak",
    "pie",
    "pine",
    "pond",
    "pool",
    "port",
    "query",
    "reef",
    "ridge",
    "rift",
    "river",
    "rock",
    "root",
    "rose",
    "rune",
    "sand",
    "server",
    "shield",
    "shore",
    "sound",
    "spark",
    "star",
    "storm",
    "tide",
    "trail",
    "vale",
    "wave"
  ]
}
