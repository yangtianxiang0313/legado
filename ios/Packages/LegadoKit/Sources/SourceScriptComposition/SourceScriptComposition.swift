import ScriptJavaScriptCore
import SourceRuntime

public enum SourceScriptComposition {
    public static func makeScriptRuntime() -> any SourceScriptRuntime {
        JavaScriptCoreSourceScriptRuntime()
    }
}
