import XCTest
@testable import Nano

@MainActor
private final class RecordingPlayer: AgentSoundPlaying {
    var played: [AgentAlertSound] = []
    func play(_ sound: AgentAlertSound) { played.append(sound) }
}

private struct FixedProbe: AgentQuietProbing {
    var value = AgentQuietConditions()
    func conditions() -> AgentQuietConditions { value }
}

/// Agent alerts: what is stored, when it is quiet, and that each request
/// sounds once and is reminded at most three times while still pending.
@MainActor
final class AgentAlertsTests: XCTestCase {
    private func attention(_ id: String, kind: AgentHookBridge.RequestKind) -> IslandAgentAttention {
        IslandAgentAttention(AgentHookBridge.PendingRequest(
            id: id,
            source: "claude",
            kind: kind,
            title: "Bash",
            detail: nil,
            options: [],
            sessionID: "s",
            receivedAt: Date(),
            projectName: "p"
        ))
    }

    private func noon() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    private func center(
        preferences: AgentAlertPreferences = AgentAlertPreferences(),
        probe: FixedProbe = FixedProbe(),
        pending: @escaping (String) -> Bool = { _ in false },
        player: RecordingPlayer,
        represented: @escaping (IslandAgentAttention) -> Void = { _ in }
    ) -> AgentAlertCenter {
        let date = noon()
        return AgentAlertCenter(
            preferences: { preferences },
            isPending: pending,
            represent: represented,
            player: player,
            probe: probe,
            now: { date },
            sleep: { _ in }
        )
    }

    // MARK: Stored values

    func testSoundsSurviveStorage() {
        for sound in [AgentAlertSound.none, .system("Glass"), .file("/Users/me/ding.wav")] {
            XCTAssertEqual(AgentAlertSound(storageValue: sound.storageValue), sound)
        }
        XCTAssertNil(AgentAlertSound(storageValue: "system:NotASound"))
        XCTAssertNil(AgentAlertSound(storageValue: "file:relative.wav"))
        XCTAssertNil(AgentAlertSound(storageValue: "garbage"))
    }

    func testPreferencesRoundTrip() throws {
        var preferences = AgentAlertPreferences()
        preferences.setSound(.file("/tmp/a.wav"), for: .approval)
        preferences.setSound(.none, for: .completion)
        preferences.quietSchedule = AgentQuietSchedule(isEnabled: true, startMinute: 22 * 60, endMinute: 7 * 60)
        preferences.remindersEnabled = true
        preferences.reminderMinutes = 5
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(AgentAlertPreferences.self, from: data), preferences)
    }

    func testEmptyOrPartialSettingsFallBackPerField() throws {
        let empty = try JSONDecoder().decode(AgentAlertPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AgentAlertPreferences())
        XCTAssertTrue(empty.soundsEnabled, "sounds are on by default")

        let partial = try JSONDecoder().decode(AgentAlertPreferences.self, from: Data("""
        {"sounds": {"approval": "system:Hero", "question": "system:Removed"}, "reminderMinutes": 7}
        """.utf8))
        XCTAssertEqual(partial.sound(for: .approval), .system("Hero"))
        XCTAssertEqual(partial.sound(for: .question), .system("Ping"), "an unreadable sound falls back to the default")
        XCTAssertEqual(partial.reminderMinutes, 2, "a reminder interval Nano doesn't offer falls back")
    }

    func testChoosingTheDefaultStoresNothing() {
        var preferences = AgentAlertPreferences()
        preferences.setSound(.system("Hero"), for: .approval)
        XCTAssertFalse(preferences.sounds.isEmpty)
        preferences.setSound(.system("Glass"), for: .approval)
        XCTAssertTrue(preferences.sounds.isEmpty)
    }

    func testEveryRequestKindHasAnEvent() {
        XCTAssertEqual(AgentAlertEvent(kind: .permission), .approval)
        XCTAssertEqual(AgentAlertEvent(kind: .question), .question)
        XCTAssertEqual(AgentAlertEvent(kind: .notification), .question)
        XCTAssertEqual(AgentAlertEvent(kind: .completion), .completion)
    }

    // MARK: Quiet

    func testQuietHoursWithinADay() {
        let schedule = AgentQuietSchedule(isEnabled: true, startMinute: 13 * 60, endMinute: 14 * 60)
        XCTAssertFalse(schedule.contains(minute: 12 * 60 + 59))
        XCTAssertTrue(schedule.contains(minute: 13 * 60))
        XCTAssertTrue(schedule.contains(minute: 13 * 60 + 59))
        XCTAssertFalse(schedule.contains(minute: 14 * 60))
    }

    func testQuietHoursPastMidnight() {
        let schedule = AgentQuietSchedule(isEnabled: true, startMinute: 23 * 60, endMinute: 8 * 60)
        XCTAssertTrue(schedule.contains(minute: 23 * 60 + 30))
        XCTAssertTrue(schedule.contains(minute: 0))
        XCTAssertTrue(schedule.contains(minute: 7 * 60 + 59))
        XCTAssertFalse(schedule.contains(minute: 8 * 60))
        XCTAssertFalse(schedule.contains(minute: 12 * 60))
    }

    func testDisabledOrEmptyScheduleIsNeverQuiet() {
        XCTAssertFalse(AgentQuietSchedule(isEnabled: false, startMinute: 0, endMinute: 1439).contains(minute: 600))
        XCTAssertFalse(AgentQuietSchedule(isEnabled: true, startMinute: 600, endMinute: 600).contains(minute: 600))
    }

    func testConditionsOnlyCountWhenTheirToggleIsOn() {
        var preferences = AgentAlertPreferences()
        let locked = AgentQuietConditions(screenLocked: true, microphoneInUse: false)
        let inCall = AgentQuietConditions(screenLocked: false, microphoneInUse: true)
        XCTAssertTrue(preferences.isQuiet(minuteOfDay: 720, conditions: locked))
        XCTAssertTrue(preferences.isQuiet(minuteOfDay: 720, conditions: inCall))
        preferences.quietWhenScreenLocked = false
        preferences.quietWhenMicrophoneInUse = false
        XCTAssertFalse(preferences.isQuiet(minuteOfDay: 720, conditions: locked))
        XCTAssertFalse(preferences.isQuiet(minuteOfDay: 720, conditions: inCall))
    }

    // MARK: Alert center

    func testEachRequestSoundsOnceWithItsEventsSound() {
        let player = RecordingPlayer()
        let alerts = center(player: player)
        alerts.didPresent(attention("a", kind: .permission))
        alerts.didPresent(attention("a", kind: .permission))
        alerts.didPresent(attention("b", kind: .completion))
        XCTAssertEqual(player.played, [.system("Glass"), .system("Pop")])
    }

    func testSoundsOffOrQuietPlaysNothing() {
        var off = AgentAlertPreferences()
        off.soundsEnabled = false
        let silentPlayer = RecordingPlayer()
        center(preferences: off, player: silentPlayer).didPresent(attention("a", kind: .question))
        XCTAssertTrue(silentPlayer.played.isEmpty)

        let quietPlayer = RecordingPlayer()
        let inCall = FixedProbe(value: AgentQuietConditions(screenLocked: false, microphoneInUse: true))
        center(probe: inCall, player: quietPlayer).didPresent(attention("a", kind: .question))
        XCTAssertTrue(quietPlayer.played.isEmpty)
    }

    func testPreviewPlaysEvenWhenQuiet() {
        let player = RecordingPlayer()
        let locked = FixedProbe(value: AgentQuietConditions(screenLocked: true, microphoneInUse: false))
        center(probe: locked, player: player).preview(.system("Tink"))
        XCTAssertEqual(player.played, [.system("Tink")])
    }

    func testPendingRequestIsRemindedThreeTimes() async {
        var preferences = AgentAlertPreferences()
        preferences.remindersEnabled = true
        let player = RecordingPlayer()
        var represented = 0
        let alerts = center(preferences: preferences, pending: { _ in true }, player: player) { _ in represented += 1 }
        alerts.didPresent(attention("a", kind: .permission))
        for _ in 0..<50 where represented < AgentAlertPreferences.maximumReminders {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(represented, 3)
        XCTAssertEqual(player.played.count, 4, "the first sound plus one per reminder")
    }

    func testAnsweredRequestsAndFinishedTurnsAreNotReminded() async {
        var preferences = AgentAlertPreferences()
        preferences.remindersEnabled = true
        let player = RecordingPlayer()
        var represented = 0
        let alerts = center(preferences: preferences, pending: { _ in false }, player: player) { _ in represented += 1 }
        alerts.didPresent(attention("answered", kind: .permission))
        alerts.didPresent(attention("done", kind: .completion))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(represented, 0)
        XCTAssertEqual(player.played.count, 2)
    }

    func testRemindersOffMeansNoReminders() async {
        let player = RecordingPlayer()
        var represented = 0
        let alerts = center(pending: { _ in true }, player: player) { _ in represented += 1 }
        alerts.didPresent(attention("a", kind: .question))
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(represented, 0)
    }
}
