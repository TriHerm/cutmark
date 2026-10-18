import Foundation
import Testing
@testable import Cutmark

struct UpdaterTests {
    @Test func sourceBuildReleaseTagMustBeReal() {
        #expect(Updater.normalizedReleaseTag(nil) == nil)
        #expect(Updater.normalizedReleaseTag("") == nil)
        #expect(Updater.normalizedReleaseTag("   \n") == nil)
        #expect(Updater.normalizedReleaseTag(" v2026.10.8 \n") == "v2026.10.8")
    }

    @Test @MainActor func sourceBuildManualCheckReportsWithoutStartingADownload() {
        guard Bundle.main.infoDictionary?["ReleaseTag"] == nil else { return }
        var message = ""
        Updater.shared.checkForUpdates { message = $0 }
        #expect(message.contains("made from source"))
        #expect(!Updater.shared.checkingRelease)
    }

    @Test func manualCheckDistinguishesCurrentStagedAndDownload() {
        #expect(Updater.releaseDisposition(latest: "v2026.10.8", own: "v2026.10.8", staged: nil) == .current)
        #expect(Updater.releaseDisposition(latest: "v2026.10.9", own: "v2026.10.8", staged: "v2026.10.9") == .staged)
        #expect(Updater.releaseDisposition(latest: "v2026.10.10", own: "v2026.10.8", staged: "v2026.10.9") == .download)
    }

    @Test func manualCheckFeedbackNamesCurrentReadyOfflineAndVerificationFailure() {
        #expect(Updater.CheckResult.current("v2026.10.8").message == "Cutmark 2026.10.8 is up to date.")
        #expect(Updater.CheckResult.ready("v2026.10.9").message == "Cutmark 2026.10.9 is ready to update.")
        #expect(Updater.CheckResult.current("release-2026.10.8").message == "Cutmark release-2026.10.8 is up to date.")
        #expect(Updater.CheckResult.unavailable.message.contains("Couldn’t check for updates"))
        #expect(Updater.CheckResult.verificationFailed("v2026.10.9").message.contains("could not be verified"))
    }

    @Test func fetchWrapperDoesNotReportAnAlreadyStagedReleaseAgain() {
        #expect(Updater.newlyStagedRelease(.ready("v2026.10.9"), skip: nil) == "v2026.10.9")
        #expect(Updater.newlyStagedRelease(.ready("v2026.10.9"), skip: "v2026.10.9") == nil)
        #expect(Updater.newlyStagedRelease(.current("v2026.10.8"), skip: nil) == nil)
        #expect(Updater.newlyStagedRelease(.verificationFailed("v2026.10.9"), skip: nil) == nil)
    }
}
