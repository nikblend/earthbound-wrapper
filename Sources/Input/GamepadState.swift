//
//  GamepadState.swift
//  EarthboundWrapper
//
//  The single place where "a finger is down" becomes "the SNES sees a button".
//
//  Buttons and the stick both contribute to one joypad bitmask. Composing them
//  here rather than in each control means there is exactly one write path to the
//  core, which is what makes it possible to reason about stuck buttons: every
//  release goes through the same recomputation, and `releaseAll` cannot miss one.
//
//  The mask is handed to the core through a C atomic, because `retro_run` reads
//  it on the emulation thread while touches arrive on the main thread.
//

import Foundation
import Observation

@MainActor
@Observable
final class GamepadState {
    /// Buttons currently held. Drives the on-screen highlight.
    private(set) var heldButtons: Set<JoypadButton> = []
    /// Direction the stick is currently reporting.
    private(set) var stickDirection: StickDirection = .none

    /// Called on the main actor when a button goes down, for haptic feedback.
    var onButtonPressed: ((JoypadButton) -> Void)?
    /// Called when the stick snaps to a different direction (including release).
    var onStickDirectionChanged: ((StickDirection) -> Void)?

    /// Whether holding A also presses Start.
    ///
    /// EarthBound uses Start exactly once -- to leave the title screen -- and never
    /// again, which is why there is no button for it: A carries it instead. It cannot be
    /// unconditional, because in other ROMs Start is the pause button and every A press
    /// would pause the game. So it is a switch, and the player decides which kind of game
    /// they are running.
    var startFollowsA = true

    private let input: OpaquePointer

    init(input: OpaquePointer) {
        self.input = input
    }

    // MARK: - Buttons

    func press(_ button: JoypadButton) {
        guard !heldButtons.contains(button) else { return }
        heldButtons.insert(button)
        push()
        onButtonPressed?(button)
    }

    func release(_ button: JoypadButton) {
        guard heldButtons.contains(button) else { return }
        heldButtons.remove(button)
        push()
    }

    func isHeld(_ button: JoypadButton) -> Bool { heldButtons.contains(button) }

    // MARK: - Stick

    func setStickDirection(_ direction: StickDirection) {
        guard direction != stickDirection else { return }
        stickDirection = direction
        push()
        onStickDirectionChanged?(direction)
    }

    // MARK: - Safety

    /// Drops every input.
    ///
    /// Called when the game loses focus, the app backgrounds, or a touch sequence
    /// is cancelled. A virtual button that stays held because its `touchesEnded`
    /// never arrived is the single most annoying way a touch emulator can fail, so
    /// this is also called defensively on scene phase changes.
    func releaseAll() {
        guard !heldButtons.isEmpty || stickDirection != .none else { return }
        heldButtons.removeAll()
        let previousDirection = stickDirection
        stickDirection = .none
        push()
        if previousDirection != .none { onStickDirectionChanged?(.none) }
    }

    // MARK: - Core handoff

    private func push() {
        var mask: UInt32 = 0
        for button in heldButtons { mask |= button.bit }
        mask |= UInt32.joypadMask(from: stickDirection)
        // Deliberately only a mask bit: Start has no on-screen button, so it never enters
        // `heldButtons` and therefore never lights anything up.
        if startFollowsA, heldButtons.contains(.a) { mask |= JoypadButton.start.bit }
        eb_input_set_mask(input, 0, mask)
    }
}
