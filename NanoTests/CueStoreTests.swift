import SwiftUI
import AppKit
import XCTest
@testable import Nano

@MainActor
final class CueStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoCue-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    func testCuesPersistWithFoldersOrderAndScope() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "harbor-next", section: .project, linkedPath: "/tmp/harbor-next/")
        store.scope = .folder(folder.id)
        let first = try XCTUnwrap(store.add(text: "Run migrations", scope: .folder(folder.id)))
        let second = try XCTUnwrap(store.add(text: "Send the RLS prompt", scope: .folder(folder.id)))
        store.reorder(second.id, before: first.id)
        store.save()

        let reloaded = CueStore(directoryURL: directory)
        XCTAssertEqual(reloaded.folders.map(\.name), ["harbor-next"])
        XCTAssertEqual(reloaded.folders.first?.linkedPath, "/tmp/harbor-next")
        XCTAssertEqual(reloaded.scope, .folder(folder.id))
        XCTAssertEqual(reloaded.openItems(in: .folder(folder.id)).map(\.text), ["Send the RLS prompt", "Run migrations"])
    }

    func testReorderMovesDownAndUp() throws {
        let store = CueStore(directoryURL: directory)
        let a = try XCTUnwrap(store.add(text: "A", scope: .inbox))
        let b = try XCTUnwrap(store.add(text: "B", scope: .inbox))
        let c = try XCTUnwrap(store.add(text: "C", scope: .inbox))

        store.reorder(a.id, before: c.id)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.text), ["B", "C", "A"])
        store.reorder(a.id, before: b.id)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.text), ["A", "B", "C"])
    }

    func testDoneCuesLeaveTheOpenListAndUndoRestoresThem() throws {
        let store = CueStore(directoryURL: directory)
        let item = try XCTUnwrap(store.add(text: "Ship it", scope: .inbox))

        // Not `copy`: tests must not replace the user's clipboard.
        store.setDone(item.id, true, announce: true)
        XCTAssertTrue(store.openItems(in: .inbox).isEmpty)
        XCTAssertEqual(store.doneItems(in: .inbox).map(\.id), [item.id])

        store.undoToast()
        XCTAssertEqual(store.openItems(in: .inbox).map(\.id), [item.id])
    }

    func testAnUnreadableLibraryIsSetAsideAndNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("cue.json")
        let corrupt = Data("{ \"folders\": [".utf8)
        try corrupt.write(to: file)

        let store = CueStore(directoryURL: directory)
        XCTAssertTrue(store.libraryIsUnreadable)
        XCTAssertNotNil(store.errorMessage)

        store.add(text: "Typed after the library failed to load", scope: .inbox)
        store.save()
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(store.errorMessage)

        let copies = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("cue.json.bad-") }
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(copies.first))), corrupt)

        // A second launch reads the same file and doesn't pile up copies.
        _ = CueStore(directoryURL: directory)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { $0.hasPrefix("cue.json.bad-") }.count,
            1
        )
    }

    func testDeleteWithUndoPutsTheCueBackWhereItWas() throws {
        let store = CueStore(directoryURL: directory)
        let a = try XCTUnwrap(store.add(text: "A", scope: .inbox))
        let b = try XCTUnwrap(store.add(text: "B", scope: .inbox))
        let c = try XCTUnwrap(store.add(text: "C", scope: .inbox))

        store.delete(b.id, undoable: true)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.id), [a.id, c.id])
        store.undoToast()
        XCTAssertEqual(store.openItems(in: .inbox).map(\.id), [a.id, b.id, c.id])
    }

    func testDeletingAFolderMovesItsCuesToTheInbox() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "Ideas", section: .stash)
        store.add(text: "Voice-first capture", scope: .folder(folder.id))

        store.deleteFolder(folder.id)
        XCTAssertEqual(store.openItems(in: .inbox).map(\.text), ["Voice-first capture"])
    }

    func testImagesAreStoredAndRemovedWithTheirCue() throws {
        let store = CueStore(directoryURL: directory)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let data = try XCTUnwrap(CueStore.pngData(image))

        let item = try XCTUnwrap(store.add(text: "", images: [data], scope: .inbox))
        let url = store.imageURL(named: try XCTUnwrap(item.images.first))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(item.headline, "Image")

        store.delete(item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDraftCommitSavesToTheChosenFolderAndKeepsItOpen() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "Prompts", section: .stash)
        store.beginCapture(text: "Draft a changelog entry")
        store.draft?.scope = .folder(folder.id)

        store.commitDraft(keepOpen: true)
        XCTAssertEqual(store.openItems(in: .folder(folder.id)).map(\.text), ["Draft a changelog entry"])
        XCTAssertEqual(store.draft?.scope, .folder(folder.id))
        XCTAssertEqual(store.draft?.text, "")
        XCTAssertEqual(store.scope, .folder(folder.id))
    }

    func testRecentProjectsSkipScratchFoldersAndFoldWorktreesIntoTheirRepository() throws {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NanoTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = root.appendingPathComponent("App", isDirectory: true)
        let worktree = root.appendingPathComponent("app-agent-1", isDirectory: true)
        let scratch = root.appendingPathComponent("2026-10-03-a-chat", isDirectory: true)
        let nested = repository.appendingPathComponent("Sources/Views", isDirectory: true)
        for folder in [repository.appendingPathComponent(".git"), worktree, scratch, nested] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try "gitdir: \(repository.path)/.git/worktrees/app-agent-1\n"
            .write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let projects = CueRecentProjects.projects(in: [
            scratch.path,
            nested.path,
            worktree.path,
            root.appendingPathComponent("deleted-agent-2").path,
            "/private/tmp",
            NSHomeDirectory(),
            repository.path,
        ])

        XCTAssertEqual(projects, [repository.path])
    }

    func testOnlyCommandVCountsAsAPaste() {
        XCTAssertTrue(CuePasteRelay.isPaste(keyCode: 9, flags: .command))
        XCTAssertTrue(CuePasteRelay.isPaste(keyCode: 9, flags: [.command, .shift]))
        XCTAssertFalse(CuePasteRelay.isPaste(keyCode: 9, flags: []))
        XCTAssertFalse(CuePasteRelay.isPaste(keyCode: 8, flags: .command))
    }

    func testKindGuessing() {
        XCTAssertEqual(CueKind.guess(for: "supabase.com/docs/guides/database"), .link)
        XCTAssertEqual(CueKind.guess(for: "https://example.com"), .link)
        XCTAssertEqual(CueKind.guess(for: "Run the migration"), .todo)
        XCTAssertEqual(CueKind.guess(for: "Nano.app/Contents"), .todo)
        XCTAssertEqual(CueKind.guess(for: "1.5/2"), .todo)
        XCTAssertEqual(CueKind.guess(for: "Line one\nLine two"), .prompt)
        XCTAssertEqual(CueKind.guess(for: String(repeating: "word ", count: 30)), .prompt)
    }

    func testDeletingAFolderCanBeUndoneAndAPassingMessageKeepsTheUndo() throws {
        let store = CueStore(directoryURL: directory)
        let folder = store.addFolder(named: "Atlas", section: .project)
        let cue = try XCTUnwrap(store.add(text: "ship it", scope: .folder(folder.id)))

        store.deleteFolder(folder.id)
        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertNil(store.items.first { $0.id == cue.id }?.folderID)

        store.showToast("Copied")
        XCTAssertEqual(store.toast?.isUndoable, true)

        store.undoToast()
        XCTAssertEqual(store.folders.map(\.id), [folder.id])
        XCTAssertEqual(store.items.first { $0.id == cue.id }?.folderID, folder.id)
    }

    func testCueFocusContinuesWithoutCompletingAndFinishesOnlyTheSelectedCue() throws {
        let suite = "NanoTests.cueCompletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandViewModel(settings: NanoSettings(defaults: defaults), trayStorageURL: nil)
        let cues = CueStore(directoryURL: directory)
        model.cueStore = cues
        let cue = try XCTUnwrap(cues.add(text: "Send report\nCheck details first", scope: .inbox))
        let other = try XCTUnwrap(cues.add(text: "Send report", scope: .inbox))
        let timer = model.timerStore
        timer.sessionName = "Regular focus draft"
        timer.addTask("Review notes")
        timer.completeCurrentTask()

        model.startCueFocus(cue.id)
        XCTAssertEqual(model.activeModule, .timer)
        XCTAssertEqual(timer.state, .running)
        XCTAssertEqual(timer.displayName, "Send report")
        XCTAssertEqual(timer.formattedRemaining, "25:00")
        model.completeCueFocus()
        XCTAssertTrue(cues.doneItems(in: .inbox).isEmpty)

        timer.finishEarly()
        model.startCueFocus(other.id)
        timer.startFocus(minutes: 50)
        timer.startOrResume()
        timer.startBreak()
        timer.addTime(5 * 60)
        XCTAssertTrue(timer.isAwaitingCueDecision)
        XCTAssertEqual(timer.remaining, 0)

        timer.keepGoing()
        XCTAssertEqual(timer.state, .running)
        XCTAssertEqual(timer.formattedRemaining, "15:00")
        XCTAssertTrue(cues.doneItems(in: .inbox).isEmpty)

        cues.update(cue.id, text: "Send the revised report")
        timer.finishEarly()
        model.completeCueFocus()
        XCTAssertEqual(model.activeModule, .cue)
        XCTAssertEqual(timer.state, .idle)
        XCTAssertFalse(timer.canUndoReset)
        XCTAssertEqual(timer.displayName, "Regular focus draft")
        XCTAssertEqual(timer.completedTaskCount, 1)
        XCTAssertNil(FocusTimerStore(defaults: defaults).cue)
        XCTAssertEqual(cues.openItems(in: .inbox).map(\.id), [other.id])
        XCTAssertEqual(CueStore(directoryURL: directory).doneItems(in: .inbox).map(\.id), [cue.id])
        cues.undoToast()
        XCTAssertEqual(Set(cues.openItems(in: .inbox).map(\.id)), [cue.id, other.id])
    }

    func testCompletingTheFocusedCueStopsItsTimer() throws {
        let suite = "NanoTests.cueFocusDone.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandViewModel(settings: NanoSettings(defaults: defaults), trayStorageURL: nil)
        let cues = CueStore(directoryURL: directory)
        model.cueStore = cues
        let focused = try XCTUnwrap(cues.add(text: "Write notes", scope: .inbox))
        let other = try XCTUnwrap(cues.add(text: "Write notes", scope: .inbox))
        let timer = model.timerStore
        defer { timer.pause() }

        model.startCueFocus(focused.id)
        cues.setDone(other.id, true)
        XCTAssertEqual(timer.state, .running)

        cues.setDone(focused.id, true, announce: true)
        XCTAssertEqual(timer.state, .idle)
        XCTAssertNil(timer.endsAt)
        XCTAssertNil(timer.cue)

        cues.undoToast()
        XCTAssertEqual(cues.openItems(in: .inbox).map(\.id), [focused.id])
        XCTAssertEqual(timer.state, .idle)

        model.startCueFocus(focused.id)
        timer.reset()
        XCTAssertTrue(timer.canUndoReset)
        cues.setDone(focused.id, true, announce: true)
        cues.undoToast()
        timer.undoReset()
        XCTAssertEqual(timer.state, .idle)
        XCTAssertFalse(timer.canUndoReset)
    }

    func testSyncedCueCompletionStopsItsPausedTimer() throws {
        let suite = "NanoTests.cueFocusSync.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandViewModel(settings: NanoSettings(defaults: defaults), trayStorageURL: nil)
        let cues = CueStore(directoryURL: directory)
        model.cueStore = cues
        let cue = try XCTUnwrap(cues.add(text: "Send the report", scope: .inbox))
        model.startCueFocus(cue.id)
        model.timerStore.pause()

        cues.applySyncEdits([.update(
            id: cue.id, expected: cue.updatedAt, text: nil, done: true, folderID: nil
        )])

        XCTAssertEqual(cues.doneItems(in: .inbox).map(\.id), [cue.id])
        XCTAssertEqual(model.timerStore.state, .idle)
        XCTAssertNil(FocusTimerStore(defaults: defaults).cue)
    }

    func testRelaunchDiscardsFocusForAnAlreadyCompletedCue() throws {
        let suite = "NanoTests.cueFocusRelaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cues = CueStore(directoryURL: directory)
        let cue = try XCTUnwrap(cues.add(text: "Close the issue", scope: .inbox))
        let previousTimer = FocusTimerStore(defaults: defaults)
        XCTAssertTrue(previousTimer.startCueFocus(FocusCue(id: cue.id, title: cue.headline)))
        previousTimer.pause()
        cues.setDone(cue.id, true)

        let restored = IslandViewModel(settings: NanoSettings(defaults: defaults), trayStorageURL: nil)
        restored.cueStore = CueStore(directoryURL: directory)

        XCTAssertEqual(restored.timerStore.state, .idle)
        XCTAssertNil(FocusTimerStore(defaults: defaults).cue)
        XCTAssertEqual(restored.cueStore.doneItems(in: .inbox).map(\.id), [cue.id])
    }

    func testExpiredCueFocusCanContinueAfterRelaunch() throws {
        let suite = "NanoTests.cueFocus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cue = FocusCue(id: UUID(), title: "Plan the next release")
        let timer = FocusTimerStore(defaults: defaults)
        XCTAssertTrue(timer.startCueFocus(cue))
        let end = try XCTUnwrap(timer.endsAt)

        let restored = FocusTimerStore(defaults: defaults, now: end.addingTimeInterval(1))
        timer.pause()
        XCTAssertTrue(restored.isAwaitingCueDecision)
        XCTAssertEqual(restored.cue, cue)
        XCTAssertEqual(restored.displayName, cue.title)
        restored.keepGoing()
        XCTAssertEqual(restored.formattedRemaining, "15:00")
        restored.pause()

        let reloaded = FocusTimerStore(defaults: defaults)
        XCTAssertEqual(reloaded.state, .paused)
        XCTAssertEqual(reloaded.cue, cue)
    }

    func testCueFocusUsesTheUsersLengthAndGivesItBack() throws {
        let suite = "NanoTests.cueLength.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandViewModel(settings: NanoSettings(defaults: defaults), trayStorageURL: nil)
        let cues = CueStore(directoryURL: directory)
        model.cueStore = cues
        let cue = try XCTUnwrap(cues.add(text: "Write notes", scope: .inbox))
        let timer = model.timerStore
        timer.setDuration(seconds: 50 * 60)

        XCTAssertEqual(timer.cueFocusLength, 50 * 60)
        model.startCueFocus(cue.id)
        XCTAssertEqual(timer.configuredDuration, 50 * 60)
        timer.finishEarly()
        timer.keepGoing()
        XCTAssertEqual(timer.configuredDuration, 65 * 60)
        timer.finishEarly()
        model.completeCueFocus()

        XCTAssertEqual(timer.state, .idle)
        XCTAssertEqual(timer.configuredDuration, 50 * 60)
        XCTAssertEqual(timer.remaining, 50 * 60)
    }

    func testNotDoneYetEndsTheSessionAndLeavesTheCueOpen() throws {
        let suite = "NanoTests.cueLeave.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = IslandViewModel(settings: NanoSettings(defaults: defaults), trayStorageURL: nil)
        let cues = CueStore(directoryURL: directory)
        model.cueStore = cues
        let cue = try XCTUnwrap(cues.add(text: "Write notes", scope: .inbox))
        let timer = model.timerStore
        timer.setDuration(seconds: 40 * 60)

        model.startCueFocus(cue.id)
        timer.finishEarly()
        model.leaveCueFocus()

        XCTAssertEqual(timer.state, .idle)
        XCTAssertNil(timer.cue)
        XCTAssertEqual(timer.configuredDuration, 40 * 60)
        XCTAssertEqual(cues.openItems(in: .inbox).map(\.id), [cue.id])
        XCTAssertTrue(timer.canStartCueFocus)
    }

    func testUndoingAResetCueSessionKeepsItsAddedTime() {
        let timer = FocusTimerStore()
        timer.setDuration(seconds: 30 * 60)
        XCTAssertTrue(timer.startCueFocus(FocusCue(id: UUID(), title: "Draft")))
        timer.finishEarly()
        timer.keepGoing()
        timer.pause()
        timer.reset()
        XCTAssertEqual(timer.configuredDuration, 30 * 60)

        timer.undoReset()
        XCTAssertEqual(timer.configuredDuration, 45 * 60)
        XCTAssertEqual(timer.cue?.title, "Draft")
        XCTAssertEqual(timer.state, .paused)
    }

    func testCueFocusRespectsTimerAvailabilityAndADeletedCue() throws {
        let suite = "NanoTests.cueAvailability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NanoSettings(defaults: defaults)
        let model = IslandViewModel(settings: settings, trayStorageURL: nil)
        let cues = CueStore(directoryURL: directory)
        model.cueStore = cues
        let cue = try XCTUnwrap(cues.add(text: "First", scope: .inbox))
        let other = try XCTUnwrap(cues.add(text: "Second", scope: .inbox))
        let timer = model.timerStore

        settings.setEnabled(false, for: .timer)
        model.startCueFocus(cue.id)
        XCTAssertEqual(timer.state, .idle)
        settings.setEnabled(true, for: .timer)
        timer.startFocus(minutes: 50)
        model.startCueFocus(cue.id)
        XCTAssertEqual(timer.configuredDuration, 50 * 60)
        timer.startFocus(minutes: 90)
        timer.pause()
        model.startCueFocus(cue.id)
        XCTAssertEqual(timer.configuredDuration, 90 * 60)
        XCTAssertEqual(timer.state, .paused)

        timer.reset()
        model.startCueFocus(cue.id)
        cues.delete(cue.id)
        timer.finishEarly()
        model.completeCueFocus()
        XCTAssertEqual(timer.state, .idle)
        XCTAssertEqual(cues.openItems(in: .inbox).map(\.id), [other.id])
        XCTAssertTrue(cues.doneItems(in: .inbox).isEmpty)
    }

    func testResetUndoRestoresACueButCannotReplaceANewSession() {
        let timer = FocusTimerStore()
        let first = FocusCue(id: UUID(), title: "First")
        let next = FocusCue(id: UUID(), title: "Next")
        XCTAssertTrue(timer.startCueFocus(first))
        timer.finishEarly()
        timer.reset()
        XCTAssertTrue(timer.canStartCueFocus)
        timer.undoReset()
        XCTAssertEqual(timer.cue, first)
        XCTAssertTrue(timer.isAwaitingCueDecision)

        timer.reset()
        XCTAssertTrue(timer.startCueFocus(next))
        timer.undoReset()
        XCTAssertFalse(timer.canUndoReset)
        XCTAssertEqual(timer.cue, next)
        XCTAssertEqual(timer.state, .running)
        timer.pause()
    }
}

@MainActor
final class BatchOneUndoTests: XCTestCase {
    func testClearingTheTrayCanBeUndone() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoTrayUndo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        let store = TrayStore(storageURL: directory.appendingPathComponent("items.json"))
        store.add([file])

        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.canUndo)

        store.undoDiscard()
        XCTAssertEqual(store.items.map(\.url), [file.standardizedFileURL])
        XCTAssertFalse(store.canUndo)
    }

    func testResettingARunningTimerCanBeUndone() {
        let store = FocusTimerStore(defaults: nil)
        store.startOrResume()
        store.reset()
        XCTAssertEqual(store.state, .idle)
        XCTAssertTrue(store.canUndoReset)

        store.undoReset()
        XCTAssertEqual(store.state, .running)
        XCTAssertFalse(store.canUndoReset)
        store.pause()
    }

    func testOpeningSomethingElseKeepsWaitingCardsForLater() {
        let center = IslandNotificationCenter()
        center.present(.preview(for: .volume))
        center.present(.preview(for: .battery))
        XCTAssertEqual(center.queuedCount, 1)

        center.setAside()
        XCTAssertNil(center.current)
        XCTAssertEqual(center.queuedCount, 1)

        center.resumeQueue()
        XCTAssertNotNil(center.current)
        XCTAssertEqual(center.queuedCount, 0)
    }
}

/// Renders Cue's island and Settings screens to /tmp/nano-shots.
@MainActor
final class CueSnapshots: XCTestCase {
    func testRenderCue() throws {
        guard ProcessInfo.processInfo.environment["NANO_SNAPSHOTS"] == "1" else { throw XCTSkip("Snapshots run on request") }
        let defaults = UserDefaults(suiteName: "nano-shots-\(UUID().uuidString)")!
        let settings = NanoSettings(defaults: defaults)
        let viewModel = IslandViewModel(settings: settings, trayStorageURL: nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NanoCueShots-\(UUID().uuidString)")
        let store = CueStore(directoryURL: directory)
        let atlas = store.addFolder(named: "Atlas-Desktop", section: .project, linkedPath: "/Users/me/Atlas-Desktop")
        _ = store.addFolder(named: "North-Star", section: .project, linkedPath: "/Users/me/North-Star")
        _ = store.addFolder(named: "Reading", section: .stash)
        _ = store.add(text: "Review the onboarding hook install and show which files changed", kind: .prompt, scope: .inbox, sourceApp: "T3 Code")
        _ = store.add(text: "Ask Fable to review Cue settings", kind: .todo, scope: .inbox)
        _ = store.add(text: "https://github.com/kitlangton/scrawl", kind: .link, scope: .inbox, sourceApp: "Safari")
        _ = store.add(text: "Per-project grouping in the agents list", kind: .idea, scope: .inbox)
        if let done = store.add(text: "Ship Batch 2 approvals", kind: .todo, scope: .inbox) { store.setDone(done.id, true) }
        _ = store.add(text: "Wire channel permissions into the MCP grants", kind: .prompt, scope: .folder(atlas.id))

        let out = URL(fileURLWithPath: "/tmp/nano-shots", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot<V: View>(_ view: V, width: CGFloat, height: CGFloat? = nil, name: String, dark: Bool = true) throws {
            let hosting = NSHostingView(rootView: view.frame(width: width, height: height)
                .fixedSize(horizontal: false, vertical: height == nil)
                .environment(\.colorScheme, .dark))
            hosting.appearance = NSAppearance(named: .darkAqua)
            let size = hosting.fittingSize
            let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: width, height: height ?? size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = hosting
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(1.2))
            let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent("\(name).png"))
            window.orderOut(nil)
        }

        // The island module at its real size, list then capture.
        try shot(CueModuleView(store: store, viewModel: viewModel).padding(15).foregroundStyle(.white).background(Color.black),
                 width: 820, height: 440, name: "cue-island")
        store.draft = CueDraft(text: "Add a ⋯ menu to every Cue row", kind: nil, images: [], scope: .inbox,
                               sourceApp: "T3 Code", pulledFromSelection: false, returnsFocus: false)
        try shot(CueModuleView(store: store, viewModel: viewModel).padding(15).foregroundStyle(.white).background(Color.black),
                 width: 640, height: 250, name: "cue-capture")
        store.draft = nil

        for tab in CueSettingsTab.allCases {
            try shot(CueSettingsPane(settings: settings, store: store, viewModel: viewModel, initialTab: tab)
                .padding(20).background(Color(nsColor: .windowBackgroundColor)), width: 760, name: "cue-settings-\(tab.rawValue)")
        }
    }
}
