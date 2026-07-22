import LegadoCore
import SourceFormat

public enum BookSourceComparisonProjection {
  public static func portableKnownFields(
    input: BookSourceDTO,
    roundTrip: BookSourceDTO
  ) -> JSONValue {
    .object(projectRoot(input: input.rawFields, roundTrip: roundTrip.rawFields))
  }

  private static func projectRoot(
    input: [String: JSONValue],
    roundTrip: [String: JSONValue]
  ) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for definition in BookSourceSchema.bookSourceFields {
      guard
        let inputValue = input[definition.jsonName],
        isPortableInput(inputValue, definition: definition),
        let roundTripValue = roundTrip[definition.jsonName]
      else { continue }
      if definition.kind == .object {
        guard
          case .object(let inputFields) = inputValue,
          let ruleDefinitions = ruleDefinitions(for: definition.jsonName)
        else { continue }
        if case .object(let roundTripFields) = roundTripValue {
          result[definition.jsonName] = .object(
            project(
              input: inputFields,
              roundTrip: roundTripFields,
              definitions: ruleDefinitions
            )
          )
        } else {
          result[definition.jsonName] = roundTripValue
        }
      } else {
        result[definition.jsonName] = canonicalValue(roundTripValue, definition: definition)
      }
    }
    return result
  }

  private static func project(
    input: [String: JSONValue],
    roundTrip: [String: JSONValue],
    definitions: [SourceFieldDefinition]
  ) -> [String: JSONValue] {
    var result: [String: JSONValue] = [:]
    for definition in definitions {
      guard
        let inputValue = input[definition.jsonName],
        isPortableInput(inputValue, definition: definition),
        let roundTripValue = roundTrip[definition.jsonName]
      else { continue }
      result[definition.jsonName] = canonicalValue(roundTripValue, definition: definition)
    }
    return result
  }

  private static func isPortableInput(
    _ value: JSONValue,
    definition: SourceFieldDefinition
  ) -> Bool {
    switch (definition.kind, value) {
    case (.string, .string), (.boolean, .bool), (.object, .object):
      true
    case (.int32, .number(let number)):
      Int32(number.rawToken) != nil
    case (.int64, .number(let number)):
      Int64(number.rawToken) != nil
    default:
      false
    }
  }

  private static func canonicalValue(
    _ value: JSONValue,
    definition: SourceFieldDefinition
  ) -> JSONValue {
    switch (definition.kind, value) {
    case (.int32, .number(let number)):
      guard let integer = Int32(number.rawToken) else { return value }
      return .number(JSONNumber(Int64(integer)))
    case (.int64, .number(let number)):
      guard let integer = Int64(number.rawToken) else { return value }
      return .number(JSONNumber(integer))
    default:
      return value
    }
  }

  private static func ruleDefinitions(for jsonName: String) -> [SourceFieldDefinition]? {
    switch jsonName {
    case "ruleSearch": BookSourceSchema.searchRuleFields
    case "ruleExplore": BookSourceSchema.exploreRuleFields
    case "ruleBookInfo": BookSourceSchema.bookInfoRuleFields
    case "ruleToc": BookSourceSchema.tocRuleFields
    case "ruleContent": BookSourceSchema.contentRuleFields
    case "ruleReview": BookSourceSchema.reviewRuleFields
    default: nil
    }
  }
}
