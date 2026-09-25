import Foundation

/// Pure state machine for the Control+Command modifier chord.
/// Fires when both are held and one is released with no other key pressed in between, so
/// shortcuts such as ⌃⌘Q, ⌃⌘Space, and ⌃⌘F keep working. Not thread-safe; feed it from one thread.
public final class ChordStateMachine {
    public struct State: Equatable, Sendable {
        public var controlDown: Bool
        public var commandDown: Bool
        public var chordArmed: Bool
        public var interrupted: Bool
    }

    private var controlDown = false
    private var commandDown = false
    private var chordArmed = false
    private var interrupted = false

    /// While true the chord and Esc emit `onCancel` (kill switch) instead of `onTrigger`.
    public var isRunActive = false
    public var onTrigger: (() -> Void)?
    public var onCancel: (() -> Void)?

    public init() {}

    public var currentState: State {
        State(controlDown: controlDown, commandDown: commandDown, chordArmed: chordArmed, interrupted: interrupted)
    }

    public func processKeyEvent(_ event: RawKeyEvent) {
        guard !event.isInjected else { return }
        if event.isKeyUp {
            handleKeyUp(event)
        } else {
            handleKeyDown(event)
        }
    }

    /// Forgets all held keys, e.g. after the event tap was disabled and key-ups may have been missed.
    public func reset() {
        controlDown = false
        commandDown = false
        chordArmed = false
        interrupted = false
    }

    private func handleKeyDown(_ event: RawKeyEvent) {
        if event.isControl {
            guard !controlDown else { return } // auto-repeat
            controlDown = true
            if commandDown && !interrupted { chordArmed = true }
            return
        }

        if event.isCommand {
            guard !commandDown else { return } // auto-repeat
            commandDown = true
            if controlDown && !interrupted { chordArmed = true }
            return
        }

        // A non-chord key while a chord modifier is held turns this into a regular shortcut. Keys typed
        // before the chord are not remembered, so they never block it.
        if controlDown || commandDown {
            interrupted = true
            chordArmed = false
        }

        if event.keyCode == RawKeyEvent.vkEscape && isRunActive {
            onCancel?()
        }
    }

    private func handleKeyUp(_ event: RawKeyEvent) {
        if event.isControl {
            controlDown = false
        } else if event.isCommand {
            commandDown = false
        } else {
            return
        }
        checkAndFireChord()
        resetInterruptedIfAllModifiersUp()
    }

    private func checkAndFireChord() {
        guard chordArmed && !interrupted else { return }
        chordArmed = false
        if isRunActive {
            onCancel?()
        } else {
            onTrigger?()
        }
    }

    private func resetInterruptedIfAllModifiersUp() {
        if !controlDown && !commandDown {
            interrupted = false
            chordArmed = false
        }
    }
}
