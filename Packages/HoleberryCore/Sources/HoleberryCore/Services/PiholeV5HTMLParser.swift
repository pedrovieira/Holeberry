import Foundation

/// Protocol for parsing Pi-hole v5 domain-list HTML tables into `DomainEntry` values.
public protocol PiholeV5HTMLParsing {
  func parseDomains(from html: String, type: Int) -> [DomainEntry]
}

/// Parses Pi-hole v5 domain-list HTML tables into `DomainEntry` values.
///
/// The v5 admin API returns domain lists as simple HTML tables. This parser extracts
/// the domain from each row's first `<td>` cell, strips any inner HTML tags, and
/// returns a flat array of entries. The header row ("Domain") is automatically filtered out.
public struct PiholeV5HTMLParser: PiholeV5HTMLParsing {
  public init() {}

  public func parseDomains(from html: String, type: Int) -> [DomainEntry] {
    guard let tableRange = html.range(of: "(?i)<table[^>]*>", options: .regularExpression) else {
      return []
    }

    let afterTable = html[tableRange.lowerBound...]
    guard let tableEnd = afterTable.range(of: "</table>", options: .caseInsensitive) else {
      return []
    }

    let tableContent = html[tableRange.lowerBound..<tableEnd.upperBound]

    let pattern = "<tr[^>]*>(.*?)</tr>"
    let rowOptions: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    guard let rowRegex = try? NSRegularExpression(pattern: pattern, options: rowOptions) else {
      return []
    }

    let nsTable = NSString(string: String(tableContent))
    let rowMatches = rowRegex.matches(
      in: String(tableContent),
      options: [],
      range: NSRange(location: 0, length: nsTable.length)
    )

    let cellPattern = "<td[^>]*>(.*?)</td>"
    let cellOptions: NSRegularExpression.Options = [.dotMatchesLineSeparators, .caseInsensitive]
    guard let cellRegex = try? NSRegularExpression(pattern: cellPattern, options: cellOptions) else {
      return []
    }

    var entries: [DomainEntry] = []
    for rowMatch in rowMatches {
      let rowString = nsTable.substring(with: rowMatch.range)
      let nsRow = NSString(string: rowString)
      let cellMatches = cellRegex.matches(in: rowString, options: [], range: NSRange(location: 0, length: nsRow.length))
      guard cellMatches.count >= 1 else { continue }

      let firstCell = nsRow.substring(with: cellMatches[0].range(at: 1))
      let domain = Self.stripHTMLTags(from: firstCell).trimmingCharacters(in: .whitespacesAndNewlines)
      if !domain.isEmpty && domain != "Domain" {
        entries.append(DomainEntry(id: nil, domain: domain, type: type, comment: nil))
      }
    }

    return entries
  }

  private static func stripHTMLTags(from string: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: [.caseInsensitive]) else {
      return string
    }
    let nsString = NSString(string: string)
    let range = NSRange(location: 0, length: nsString.length)
    return regex.stringByReplacingMatches(in: string, range: range, withTemplate: "")
  }
}
