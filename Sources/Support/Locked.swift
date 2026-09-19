//
//  Locked.swift
//  EarthboundWrapper
//
//  A mutex and the state it protects, in one object.
//
//  `NSLock` rather than `OSAllocatedUnfairLock`, and not for performance: the
//  latter's generic parameter is constrained to `Sendable`, and several things
//  guarded here are raw pointers into the core's memory, which are not. Wrapping
//  them would mean an `@unchecked Sendable` box that asserts exactly what these
//  locks already guarantee.
//
//  Nothing on a real-time thread ever takes one of these. The audio ring and the
//  joypad word are lock-free C; the locks here cover the environment callback's
//  option store, the frame handoff between the emulation thread and the draw loop,
//  and the session's command queue. All are cold paths where an uncontended
//  `NSLock` is a handful of instructions.
//

import Foundation

final class Locked<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ initialState: State) {
        state = initialState
    }

    /// Runs `body` with exclusive access to the state.
    ///
    /// Deliberately not reentrant, and deliberately not `@Sendable`: the closure
    /// usually touches captured pointers and objects that are not sendable, and
    /// which the caller has already reasoned about. Holding the lock while doing
    /// real work in `body` is what the type is for.
    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&state)
    }
}
