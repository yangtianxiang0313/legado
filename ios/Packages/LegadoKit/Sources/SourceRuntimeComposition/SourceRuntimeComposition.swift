import HTMLSwiftSoup
import RuleRuntime

public enum SourceRuntimeComposition {
    public static func makeHTMLSelectorBackend() -> any HTMLSelectorBackend {
        SwiftSoupHTMLSelectorBackend()
    }
}
