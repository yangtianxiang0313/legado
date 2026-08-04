import Foundation

/// A source-aligned port of Android `ContentHelp.reSegment`.
///
/// The random value is injectable so Android/iOS fixtures can replay the same
/// long-paragraph split decisions. Production callers use the system RNG.
public enum AndroidContentResegment {
  public static func resegment(
    _ content: String,
    chapterName: String,
    random: () -> Double = { Double.random(in: 0..<1) }
  ) -> String {
    let dictionary = makeDictionary(content)
    var prepared = regexReplace(content, #"&quot;"#, "“")
    prepared = regexReplace(prepared, #"[:：]['\"‘”“]+"#, "：“")
    prepared = regexReplace(prepared, #"[\"”“]+[\s]*[\"”“][\s\"”“]*"#, "”\n“")
    let parts = prepared.components(
      separatedBy: try! NSRegularExpression(pattern: #"\n(\s*)"#)
    )

    var joined = " "
    if let first = parts.first,
       chapterName.trimmingCharacters(in: .whitespacesAndNewlines)
        != first.trimmingCharacters(in: .whitespacesAndNewlines) {
      joined += regexReplace(first, #"[\u3000\s]+"#, "")
    }
    for part in parts.dropFirst() {
      if let last = joined.last, sentenceEnds.contains(last) { joined += "\n" }
      joined += regexReplace(part, #"[\u3000\s]"#, "")
    }

    joined = regexReplace(joined, #"[\"”“]+[\s]*[\"”“]+"#, "”\n“")
    joined = regexReplace(joined, #"[\"”“]+(？。！?!~)[\"”“]+"#, "”$1\n“")
    joined = regexReplace(joined, #"[\"”“]+(？。！?!~)([^\"”“])"#, "”$1\n$2")
    joined = regexReplace(joined, #"([问说喊唱叫骂道着答])[\.。]"#, "$1。\n")

    var result = ""
    for part in joined.components(separatedBy: "\n") {
      result += "\n" + findNewLines(part, dictionary: dictionary, random: random)
    }
    result = reduceLength(result)
    result = regexReplace(result, #"^\s+"#, "", firstOnly: true)
    result = regexReplace(result, #"\s*[\"”“]+[\s]*[\"”“][\s\"”“]*"#, "”\n“")
    result = regexReplace(result, #"[:：][”“\"\s]+"#, "：“")
    result = regexReplace(result, #"\n[\"“”]([^\n\"“”]+)([,:，：][\"”“])([^\n\"“”]+)"#, "\n$1：“$3")
    return regexReplace(result, #"\n(\s*)"#, "\n")
  }

  private static func reduceLength(_ value: String) -> String {
    var parts = value.components(separatedBy: "\n")
    let dialogueFlags = parts.map { regexMatches($0, #"^[\"”“][^\"”“]+[\"”“]$"#) }
    var dialogue = 0
    for index in parts.indices {
      if dialogueFlags[index] {
        if dialogue < 0 { dialogue = 1 } else if dialogue < 2 { dialogue += 1 }
      } else if dialogue > 1 {
        parts[index] = splitQuote(parts[index])
        dialogue -= 1
      } else if dialogue > 0, index < parts.count - 2, dialogueFlags[index + 1] {
        parts[index] = splitQuote(parts[index])
      }
    }
    return parts.reduce(into: "") { $0 += "\n" + $1 }
  }

  private static func splitQuote(_ value: String) -> String {
    let chars = Array(value)
    guard chars.count >= 3 else { return value }
    if quotationMarks.contains(chars[0]) {
      let index = seekIndex(chars, key: quotationMarks, from: 1, to: chars.count - 2, forward: true) + 1
      if index > 1, !quotationBefore.contains(chars[index - 1]) {
        return String(chars[..<index]) + "\n" + String(chars[index...])
      }
    } else if quotationMarks.contains(chars[chars.count - 1]) {
      let index = chars.count - 1 - seekIndex(chars, key: quotationMarks, from: 1, to: chars.count - 2, forward: false)
      if index > 1, !quotationBefore.contains(chars[index - 1]) {
        return String(chars[..<index]) + "\n" + String(chars[index...])
      }
    }
    return value
  }

  private static func forceSplit(
    _ chars: [Character], offset: Int, minimum: Int, gain: Int, trigger: Int,
    random: () -> Double
  ) -> [Int] {
    let ends = seekIndexes(chars, key: sentenceEndsWithPeriod, from: 0, to: chars.count - 2)
    let middles = seekIndexes(chars, key: sentenceMiddles, from: 0, to: chars.count - 2)
    guard ends.count >= trigger || middles.count >= trigger * 3 else { return [] }
    var result: [Int] = []
    var j = 0
    var i = minimum
    while i < ends.count {
      var k = 0
      while j < middles.count {
        if middles[j] < ends[i] { k += 1 }
        j += 1
      }
      if random() * Double(gain) < 0.8 + Double(k) / 2.5 {
        result.append(ends[i] + offset)
        i = max(i + minimum, i)
      }
      i += 1
    }
    return result
  }

  private static func findNewLines(
    _ value: String, dictionary: [String], random: () -> Double
  ) -> String {
    let original = Array(value)
    var chars = original
    var quotes: [Int] = []
    var lineBreaks: [Int] = []
    var modes = Array(repeating: 0, count: original.count)
    var waitingForClose = false

    for index in original.indices where quotationMarks.contains(original[index]) {
      let size = quotes.count
      if size > 0 {
        let previous = quotes[size - 1]
        if index - previous == 2 {
          let separator = original[index - 1]
          let remove = waitingForClose
            ? CharacterSetLike(",，、/").contains(separator)
            : CharacterSetLike(",，、/和与或").contains(separator)
          if remove {
            chars[index] = "“"
            chars[index - 2] = "”"
            quotes.removeLast()
            modes[size - 1] = 1
            modes[size] = -1
            continue
          }
        }
      }
      quotes.append(index)
      if index > 1 {
        let before = original[index - 1]
        var previousSpeech: Character = "\0"
        if quotationBefore.contains(before) {
          if quotes.count > 1 {
            let lastQuote = quotes[quotes.count - 2]
            var point = 0
            if before == "," || before == "，", quotes.count > 2 {
              point = quotes[quotes.count - 3]
              if point > 0 { previousSpeech = original[point - 1] }
            }
            if sentenceEndsWithPeriod.contains(previousSpeech) {
              lineBreaks.append(point - 1)
            } else if previousSpeech != "的" {
              let lastEnd = seekLast(original, key: sentenceEnds, from: index, to: lastQuote)
              lineBreaks.append(lastEnd > 0 ? lastEnd : lastQuote)
            }
          }
          waitingForClose = true
          modes[size] = 1
          if size > 0 {
            modes[size - 1] = -1
            if size > 1 { modes[size - 2] = 1 }
          }
        } else if waitingForClose {
          waitingForClose = false
          lineBreaks.append(index)
        }
      }
    }

    let quoteCount = quotes.count
    var opened = false
    if quoteCount > 0 {
      for index in 0..<quoteCount {
        if modes[index] > 0 { opened = true }
        else if modes[index] < 0 {
          if !opened, index > 0 { modes[index] = 3 }
          opened = false
        } else {
          opened.toggle()
          modes[index] = opened ? 2 : -2
        }
      }
      if opened {
        if quotes[quoteCount - 1] - chars.count > -3 {
          if quoteCount > 1 { modes[quoteCount - 2] = 4 }
          modes[quoteCount - 1] = -4
        } else if chars.count >= 2, !speechVerbs.contains(chars[chars.count - 2]) {
          chars.append("”")
        }
      }

      var previousMode = -1
      var start = 0
      if quotes[0] - 1 < 0 { start = 1; previousMode = 0 }
      if start < quoteCount {
        for index in start..<quoteCount {
          let point = quotes[index] - 1
          let mode = modes[index]
          if previousMode < 0, mode > 0, point >= 0, sentenceEnds.contains(chars[point]) {
            lineBreaks.append(point)
          }
          previousMode = mode
        }
      }
    }

    lineBreaks = lineBreaks.filter { point in
      guard point >= 0, point < original.count else { return false }
      if CharacterSetLike("\"'”“").contains(original[point]) {
        let start = seekLast(original, key: CharacterSetLike("\"'”“"), from: point - 1, to: point - wordMaxLength)
        if start > 0 {
          let word = String(original[(start + 1)..<point])
          if dictionary.contains(word) { return false }
          if CharacterSetLike("的地得").contains(original[start]) { return false }
        }
      }
      return true
    }
    lineBreaks = Array(Set(lineBreaks)).sorted()

    var progress = 0
    var quoteCursor = 0
    var minimum = 0
    var gain = 3
    var trigger = 2
    let fixedBreaks = lineBreaks
    for quote in quotes {
      if quote > 0 { gain = 4; minimum = 2; trigger = 4 }
      else { gain = 3; minimum = 0; trigger = 2 }
      while quoteCursor < fixedBreaks.count, fixedBreaks[quoteCursor] < quote {
        let next = fixedBreaks[quoteCursor]
        if progress < next {
          lineBreaks += forceSplit(Array(chars[progress..<next]), offset: progress, minimum: minimum, gain: gain, trigger: trigger, random: random)
          progress = next + 1
        }
        quoteCursor += 1
      }
      if progress < quote, quote < chars.count {
        lineBreaks += forceSplit(Array(chars[progress...quote]), offset: progress, minimum: minimum, gain: gain, trigger: trigger, random: random)
        progress = quote + 1
      }
    }
    while quoteCursor < fixedBreaks.count {
      let next = fixedBreaks[quoteCursor]
      if progress < next {
        lineBreaks += forceSplit(Array(chars[progress..<next]), offset: progress, minimum: minimum, gain: gain, trigger: trigger, random: random)
        progress = next + 1
      }
      quoteCursor += 1
    }
    if progress < chars.count {
      lineBreaks += forceSplit(Array(chars[progress...]), offset: progress, minimum: minimum, gain: gain, trigger: trigger, random: random)
    }

    var insertQuote = Array(repeating: false, count: quoteCount)
    opened = false
    for index in 0..<quoteCount {
      let point = quotes[index]
      if modes[index] > 0 {
        chars[point] = "“"
        if opened { insertQuote[index] = true }
        opened = true
      } else if modes[index] < 0 {
        chars[point] = "”"
        opened = false
      } else {
        opened.toggle()
        chars[point] = opened ? "“" : "”"
      }
    }

    let breaks = Array(Set(lineBreaks.filter { $0 >= 0 && $0 < chars.count })).sorted()
    var output = ""
    var cursor = 0
    var breakCursor = 0
    for (quoteIndex, quote) in quotes.enumerated() {
      while breakCursor < breaks.count, breaks[breakCursor] < quote {
        let next = breaks[breakCursor]
        if cursor <= next { output += String(chars[cursor...next]) + "\n"; cursor = next + 1 }
        breakCursor += 1
      }
      if cursor < quote { output += String(chars[cursor...quote]); cursor = quote + 1 }
      if insertQuote[quoteIndex], output.count > 2 {
        if output.last == "\n" { output += "“" }
        else { output.insert(contentsOf: "”\n", at: output.index(before: output.endIndex)) }
      }
    }
    while breakCursor < breaks.count {
      let next = breaks[breakCursor]
      if cursor <= next { output += String(chars[cursor...next]) + "\n"; cursor = next + 1 }
      breakCursor += 1
    }
    if cursor < chars.count { output += String(chars[cursor...]) }
    return output
  }

  private static func makeDictionary(_ value: String) -> [String] {
    guard let regex = try? NSRegularExpression(
      pattern: #"(?<=[\"'”“])([^\n\p{P}]{1,16})(?=[\"'”“])"#
    ) else { return [] }
    let ns = value as NSString
    var seen = Set<String>()
    var dictionary: [String] = []
    for match in regex.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
      let word = ns.substring(with: match.range)
      if seen.contains(word), !dictionary.contains(word) { dictionary.append(word) }
      else { seen.insert(word) }
    }
    return dictionary
  }

  private static func seekIndexes(_ chars: [Character], key: CharacterSetLike, from: Int, to: Int) -> [Int] {
    guard chars.count - from >= 1 else { return [] }
    var index = max(0, from)
    let end = to > 0 ? min(chars.count, to) : chars.count
    var result: [Int] = []
    while index < end { if key.contains(chars[index]) { result.append(index) }; index += 1 }
    return result
  }

  private static func seekLast(_ chars: [Character], key: CharacterSetLike, from: Int, to: Int) -> Int {
    guard chars.count - from >= 1 else { return -1 }
    var index = min(chars.count - 1, from)
    let end = to > 0 ? to : 0
    while index > end { if key.contains(chars[index]) { return index }; index -= 1 }
    return -1
  }

  private static func seekIndex(_ chars: [Character], key: CharacterSetLike, from: Int, to: Int, forward: Bool) -> Int {
    guard chars.count - from >= 1 else { return -1 }
    var index = max(0, from)
    let end = to > 0 ? min(chars.count, to) : chars.count
    while index < end {
      let candidate = forward ? chars[index] : chars[chars.count - index - 1]
      if key.contains(candidate) { return index }
      index += 1
    }
    return -1
  }

  private static func regexReplace(_ value: String, _ pattern: String, _ replacement: String, firstOnly: Bool = false) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
    let range = NSRange(location: 0, length: (value as NSString).length)
    if firstOnly, let match = regex.firstMatch(in: value, range: range) {
      return regex.stringByReplacingMatches(in: value, range: match.range, withTemplate: replacement)
    }
    return regex.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
  }

  private static func regexMatches(_ value: String, _ pattern: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let range = NSRange(location: 0, length: (value as NSString).length)
    return regex.firstMatch(in: value, range: range)?.range == range
  }

  private struct CharacterSetLike {
    let values: Set<Character>
    init(_ value: String) { values = Set(value) }
    func contains(_ value: Character) -> Bool { values.contains(value) }
  }

  private static let sentenceEnds = CharacterSetLike("？。！?!~")
  private static let sentenceEndsWithPeriod = CharacterSetLike(".？。！?!~")
  private static let sentenceMiddles = CharacterSetLike(".，、,—…")
  private static let speechVerbs = CharacterSetLike("问说喊唱叫骂道着答")
  private static let quotationBefore = CharacterSetLike("，：,:")
  private static let quotationMarks = CharacterSetLike("\"“”")
  private static let wordMaxLength = 16
}

private extension String {
  func components(separatedBy regex: NSRegularExpression) -> [String] {
    let ns = self as NSString
    var result: [String] = []
    var start = 0
    for match in regex.matches(in: self, range: NSRange(location: 0, length: ns.length)) {
      result.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
      start = match.range.location + match.range.length
    }
    result.append(ns.substring(from: start))
    return result
  }
}
