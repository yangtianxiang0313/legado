import NetworkFoundation
import SourceRuntime

public enum SourceNetworkComposition {
    public static func makeTransport() -> any HTTPTransport {
        URLSessionHTTPTransport()
    }
}
