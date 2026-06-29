import Foundation
import Testing

@Suite("Script workflows")
struct ScriptWorkflowTests {
    @Test("smoke diagnostics script refuses pre-existing RememBar instead of killing globally")
    func smokeDiagnosticsScriptRefusesPreexistingRememBarInsteadOfKillingGlobally() throws {
        let script = try projectTextFile("scripts/smoke-remembar-diagnostics.sh")

        for forbiddenCommand in ["pkill", "killall"] {
            #expect(!script.contains(forbiddenCommand))
        }

        #expect(script.contains("existing RememBar process is running"))
        #expect(script.split(separator: "\n").filter { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("kill ")
        }.allSatisfy { line in
            line.contains("\"$app_pid\"")
        })
        #expect(occurrences(of: "kill -KILL \"$app_pid\"", in: script) == 1)
    }

    @Test("build script uses Swift bin path and project local icon source")
    func buildScriptUsesSwiftBinPathAndProjectLocalIconSource() throws {
        let script = try projectTextFile("scripts/build-remembar-app.sh")

        #expect(script.contains("--show-bin-path"))
        #expect(script.contains("swift build --package-path \"$PROJECT_DIR\" --configuration \"$CONFIGURATION\""))
        #expect(script.contains("swift build --package-path \"$PROJECT_DIR\" --configuration \"$CONFIGURATION\" --show-bin-path"))
        #expect(!matches(script, pattern: #"\.build/[A-Za-z0-9_]+-apple-macosx"#))
        #expect(!script.contains("menu-bar-prototype"))
        #expect(script.contains("REMEMBAR_ICON_SOURCE"))
        #expect(script.contains("Sources/BrowserMemoryBar/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png"))
        #expect(script.contains("cp \"$BUILD_DIR/$EXECUTABLE_NAME\""))

        let iconCheck = "[ -f \"$ICON_SOURCE\" ] || fail \"missing icon source at $ICON_SOURCE\""
        let buildCommand = "swift build --package-path \"$PROJECT_DIR\" --configuration \"$CONFIGURATION\""
        let removeCommand = "rm -rf \"$APP_DIR\" \"$ICONSET_DIR\""
        #expect(script.contains(iconCheck))
        let iconCheckRange = try #require(script.range(of: iconCheck))
        let buildRange = try #require(script.range(of: buildCommand))
        let removeRange = try #require(script.range(of: removeCommand))
        #expect(iconCheckRange.lowerBound < buildRange.lowerBound)
        #expect(iconCheckRange.lowerBound < removeRange.lowerBound)
    }
}

private func projectTextFile(_ relativePath: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

private func matches(_ text: String, pattern: String) -> Bool {
    (try? NSRegularExpression(pattern: pattern).firstMatch(
        in: text,
        range: NSRange(text.startIndex..., in: text)
    )) != nil
}
