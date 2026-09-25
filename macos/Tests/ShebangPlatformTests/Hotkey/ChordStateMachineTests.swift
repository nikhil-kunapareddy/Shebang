import Testing
@testable import ShebangPlatform

/// Shorthands for building key events in the hotkey tests.
extension RawKeyEvent {
    static func keyDown(_ keyCode: UInt16, isInjected: Bool = false) -> RawKeyEvent {
        RawKeyEvent(keyCode: keyCode, isKeyUp: false, isInjected: isInjected)
    }

    static func keyUp(_ keyCode: UInt16, isInjected: Bool = false) -> RawKeyEvent {
        RawKeyEvent(keyCode: keyCode, isKeyUp: true, isInjected: isInjected)
    }
}

private final class ChordCounter {
    var triggers = 0
    var cancels = 0
}

@Suite struct ChordStateMachineTests {
    private let machine = ChordStateMachine()
    private let counter = ChordCounter()

    private let control = RawKeyEvent.vkControl
    private let rightControl = RawKeyEvent.vkRightControl
    private let command = RawKeyEvent.vkCommand
    private let rightCommand = RawKeyEvent.vkRightCommand
    private let keyQ: UInt16 = 0x0C
    private let keyD: UInt16 = 0x02
    private let space: UInt16 = 0x31

    init() {
        machine.onTrigger = { [counter] in counter.triggers += 1 }
        machine.onCancel = { [counter] in counter.cancels += 1 }
    }

    private func send(_ events: RawKeyEvent...) {
        events.forEach(machine.processKeyEvent)
    }

    @Test func controlDownCommandDownCommandUp_firesExactlyOnce() {
        send(.keyDown(control), .keyDown(command), .keyUp(command), .keyUp(control))
        #expect(counter.triggers == 1)
        #expect(counter.cancels == 0)
    }

    @Test func commandDownControlDownControlUp_firesExactlyOnce() {
        send(.keyDown(command), .keyDown(control), .keyUp(control), .keyUp(command))
        #expect(counter.triggers == 1)
        #expect(counter.cancels == 0)
    }

    @Test(arguments: [UInt16(0x02), 0x0C, 0x31, 0x03]) // D, Q, Space, F
    func interveningKey_doesNotFire(key: UInt16) {
        send(.keyDown(control), .keyDown(command), .keyDown(key), .keyUp(key), .keyUp(command), .keyUp(control))
        #expect(counter.triggers == 0)
        #expect(counter.cancels == 0)
    }

    @Test func shortcutThenCleanChord_firesOnlyForTheCleanChord() {
        send(.keyDown(control), .keyDown(command), .keyDown(keyQ), .keyUp(keyQ), .keyUp(command), .keyUp(control))
        send(.keyDown(control), .keyDown(command), .keyUp(command), .keyUp(control))
        #expect(counter.triggers == 1)
    }

    @Test func controlAloneOrCommandAlone_doesNotFire() {
        send(.keyDown(control), .keyUp(control))
        #expect(counter.triggers == 0)
        send(.keyDown(command), .keyUp(command))
        #expect(counter.triggers == 0)
    }

    @Test func leftAndRightModifierVariants_bothWork() {
        send(.keyDown(rightControl), .keyDown(command), .keyUp(command), .keyUp(rightControl))
        #expect(counter.triggers == 1)
        send(.keyDown(control), .keyDown(rightCommand), .keyUp(rightCommand), .keyUp(control))
        #expect(counter.triggers == 2)
    }

    @Test func injectedEvents_areIgnored() {
        send(
            .keyDown(control, isInjected: true), .keyDown(command, isInjected: true),
            .keyUp(command, isInjected: true), .keyUp(control, isInjected: true))
        #expect(counter.triggers == 0)
    }

    @Test func injectedEscapeWhileRunning_isNotAKillSwitch() {
        machine.isRunActive = true
        send(.keyDown(RawKeyEvent.vkEscape, isInjected: true), .keyUp(RawKeyEvent.vkEscape, isInjected: true))
        #expect(counter.cancels == 0)
    }

    @Test func chordWhileRunActive_emitsCancelNotTrigger() {
        machine.isRunActive = true
        send(.keyDown(control), .keyDown(command), .keyUp(command), .keyUp(control))
        #expect(counter.triggers == 0)
        #expect(counter.cancels == 1)
    }

    @Test func escapeWhileRunActive_emitsCancel() {
        machine.isRunActive = true
        send(.keyDown(RawKeyEvent.vkEscape), .keyUp(RawKeyEvent.vkEscape))
        #expect(counter.triggers == 0)
        #expect(counter.cancels == 1)
    }

    @Test func escapeWhenIdle_doesNothing() {
        send(.keyDown(RawKeyEvent.vkEscape), .keyUp(RawKeyEvent.vkEscape))
        #expect(counter.triggers == 0)
        #expect(counter.cancels == 0)
    }

    @Test func keyAutoRepeat_doesNotDoubleFire() {
        send(.keyDown(control), .keyDown(command), .keyDown(command), .keyDown(command), .keyUp(command), .keyUp(control))
        #expect(counter.triggers == 1)
    }

    @Test func typingBeforeTheChord_doesNotBlockIt() {
        send(.keyDown(keyD), .keyUp(keyD), .keyDown(space), .keyUp(space))
        send(.keyDown(control), .keyDown(command), .keyUp(command), .keyUp(control))
        #expect(counter.triggers == 1)
    }

    @Test func releasingFirstModifier_firesOnceEvenWhenSecondIsReleasedLater() {
        send(.keyDown(control), .keyDown(command), .keyUp(control))
        #expect(counter.triggers == 1)
        send(.keyUp(command))
        #expect(counter.triggers == 1)
        #expect(machine.currentState == .init(controlDown: false, commandDown: false, chordArmed: false, interrupted: false))
    }

    @Test func reset_clearsHeldModifiers() {
        send(.keyDown(control), .keyDown(command))
        #expect(machine.currentState.chordArmed)
        machine.reset()
        #expect(machine.currentState == .init(controlDown: false, commandDown: false, chordArmed: false, interrupted: false))
        // A stale Command key-up after the reset must not fire.
        send(.keyUp(command))
        #expect(counter.triggers == 0)
    }
}

@Suite struct RawKeyEventFlagsTests {
    private let controlDown: UInt64 = RawKeyEvent.flagControl | RawKeyEvent.deviceLeftControl
    private let commandDown: UInt64 = RawKeyEvent.flagCommand | RawKeyEvent.deviceLeftCommand

    @Test func leftControlPressAndRelease() throws {
        let down = try #require(RawKeyEvent.fromFlagsChanged(keyCode: RawKeyEvent.vkControl, flags: controlDown))
        #expect(down == .keyDown(RawKeyEvent.vkControl))
        let up = try #require(RawKeyEvent.fromFlagsChanged(keyCode: RawKeyEvent.vkControl, flags: 0))
        #expect(up == .keyUp(RawKeyEvent.vkControl))
    }

    @Test func releasingLeftControlWhileRightControlHeld_isKeyUp() throws {
        let flags = RawKeyEvent.flagControl | RawKeyEvent.deviceRightControl
        let event = try #require(RawKeyEvent.fromFlagsChanged(keyCode: RawKeyEvent.vkControl, flags: flags))
        #expect(event.isKeyUp)
        let right = try #require(RawKeyEvent.fromFlagsChanged(keyCode: RawKeyEvent.vkRightControl, flags: flags))
        #expect(!right.isKeyUp)
    }

    @Test func commandWithoutDeviceBits_fallsBackToGenericFlag() throws {
        let event = try #require(RawKeyEvent.fromFlagsChanged(keyCode: RawKeyEvent.vkRightCommand, flags: RawKeyEvent.flagCommand))
        #expect(!event.isKeyUp)
        #expect(event.isCommand)
    }

    @Test func shiftDuringChord_interruptsIt() throws {
        let machine = ChordStateMachine()
        var fired = 0
        machine.onTrigger = { fired += 1 }
        let shiftDown = try #require(RawKeyEvent.fromFlagsChanged(
            keyCode: RawKeyEvent.vkShift, flags: controlDown | commandDown | RawKeyEvent.flagShift))
        #expect(!shiftDown.isControl && !shiftDown.isCommand)

        machine.processKeyEvent(.keyDown(RawKeyEvent.vkControl))
        machine.processKeyEvent(.keyDown(RawKeyEvent.vkCommand))
        machine.processKeyEvent(shiftDown)
        machine.processKeyEvent(.keyUp(RawKeyEvent.vkCommand))
        machine.processKeyEvent(.keyUp(RawKeyEvent.vkControl))
        #expect(fired == 0)
    }

    @Test func nonModifierKeyCode_isIgnored() {
        #expect(RawKeyEvent.fromFlagsChanged(keyCode: 0x00, flags: controlDown) == nil)
    }

    @Test func injectedFlagIsPreserved() throws {
        let event = try #require(RawKeyEvent.fromFlagsChanged(keyCode: RawKeyEvent.vkCommand, flags: commandDown, isInjected: true))
        #expect(event.isInjected)
    }
}
