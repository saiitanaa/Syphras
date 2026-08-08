//
//  AppState.swift
//  Syphras
//
//  Created by saiitanaa on 02/08/2026.
//

import SwiftUI
import Combine
import Foundation
import os

private let appStateLogger = Logger(subsystem: "com.saiitanaa.syphras", category: "appstate")

@MainActor
final class AppState: ObservableObject {
    @Published var showUpdateAlert = false
    @Published var availableRelease: GitHubRelease?

    @Published var showNoUpdateAlert = false
    @Published var showUpdateErrorAlert = false
    @Published var updateErrorMessage: String?

    private let updateChecker = UpdateChecker(owner: "saiitanaa", repo: "Syphras")
    private let lastCheckKey = "lastUpdateCheckDate"

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func checkForUpdateOnLaunch() async {
        if let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 86400 {
            return
        }
        await performCheck(showFeedbackIfNoUpdate: false)
    }

    func checkForUpdateManually() async {
        await performCheck(showFeedbackIfNoUpdate: true)
    }

    private func performCheck(showFeedbackIfNoUpdate: Bool) async {
        do {
            let release = try await updateChecker.fetchLatestRelease()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)

            guard !release.prerelease, !release.draft else {
                if showFeedbackIfNoUpdate { showNoUpdateAlert = true }
                return
            }

            if UpdateChecker.isNewer(latest: release.tagName, than: currentVersion) {
                self.availableRelease = release
                self.showUpdateAlert = true
            } else if showFeedbackIfNoUpdate {
                self.showNoUpdateAlert = true
            }
        } catch {
            appStateLogger.error("Update check failed: \(error.localizedDescription)")
            if showFeedbackIfNoUpdate {
                self.updateErrorMessage = error.localizedDescription
                self.showUpdateErrorAlert = true
            }
        }
    }
}
