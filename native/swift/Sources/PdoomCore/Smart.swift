// Typographic punctuation for display text, ported line for line from app/src/engine/type.ts `smart`.
// Leading elisions ('cause, 'til, 'em, '90s) get an apostrophe, not an opening quote.
import Foundation

private func replace(_ s: String, _ pattern: String, _ template: String, options: NSRegularExpression.Options = []) -> String {
  let re = try! NSRegularExpression(pattern: pattern, options: options)
  let range = NSRange(s.startIndex..., in: s)
  return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
}

public func smart(_ s: String) -> String {
  var out = s
  out = out.replacingOccurrences(of: "...", with: "\u{2026}")
  // leading elision: (^|[\s([{—–-])'(?=(?:cause|cos|til|em|round|n|tis|twas|\d0s)\b)  ->  $1’
  // (ICU character classes treat an unescaped '[' as a nested-set start, unlike JS; escape it here)
  out = replace(out, "(^|[\\s(\\[{—–-])'(?=(?:cause|cos|til|em|round|n|tis|twas|\\d0s)\\b)", "$1\u{2019}", options: [.caseInsensitive])
  // opening single quote: (^|[\s([{—–-])'  ->  $1‘
  out = replace(out, "(^|[\\s(\\[{—–-])'", "$1\u{2018}")
  // every remaining ' -> ’
  out = out.replacingOccurrences(of: "'", with: "\u{2019}")
  // opening double quote: (^|[\s([{—–-])\"  ->  $1“
  out = replace(out, "(^|[\\s(\\[{—–-])\"", "$1\u{201C}")
  out = out.replacingOccurrences(of: "\"", with: "\u{201D}")
  return out
}

/// Typewriter quotes back (type.ts `plain`).
public func plainQuotes(_ s: String) -> String {
  var out = s
  out = out.replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
  out = out.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
  out = out.replacingOccurrences(of: "\u{2026}", with: "...")
  return out
}
