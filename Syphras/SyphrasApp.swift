import SwiftUI

@main
struct SyphrasApp: App {
    @StateObject private var appState = AppState()

    private var creditsAttributedString: NSAttributedString {
        let text = "Created by Saiitanaa\n\nSource code: GitHub"
        let licence = "GPL-3.0 Licence"
        let combinedText = "\(text)\n\n\(licence)"
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributedString = NSMutableAttributedString(
            string: combinedText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraphStyle
            ]
        )

        if let linkRange = combinedText.range(of: "GitHub") {
            let nsRange = NSRange(linkRange, in: combinedText)
            if let url = URL(string: "https://github.com/saiitanaa/Syphras") {
                attributedString.addAttribute(.link, value: url, range: nsRange)
            }
        }

        return attributedString
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Syphras") {
                    NSApplication.shared.orderFrontStandardAboutPanel(
                        options: [
                            .credits: creditsAttributedString
                        ]
                    )
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates") {
                    Task { await appState.checkForUpdateManually() }
                }
            }
        }
    }
}
