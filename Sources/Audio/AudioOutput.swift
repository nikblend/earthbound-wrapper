//
//  AudioOutput.swift
//  EarthboundWrapper
//
//  CoreAudio side of the audio path.
//
//  The core produces 16-bit stereo at its native rate (~32 kHz for SNES) on the
//  emulation thread. We hand that to a lock-free ring and let an
//  `AVAudioSourceNode` pull it from the real-time render thread, converting to
//  float and resampling to the hardware rate for free, because the engine's
//  converter sits between the node and the mixer.
//
//  The render block must never allocate, lock, or block. Everything it touches
//  is preallocated, and an under-run fades to silence instead of clicking.
//

import AVFoundation
import Foundation
import os

final class AudioOutput {
    /// ~192 ms of storage. The pacing servo in `EmulatorSession` aims for
    /// `targetFill`, so what actually costs latency is the target, not the
    /// capacity; the slack above the target is what absorbs CoreAudio's callback
    /// jitter and a hitch in the emulation thread.
    static let ringCapacityBytes = 24_576
    /// 22% of the ring, about 42 ms of audio. Low enough that the tactile
    /// feedback does not feel detached from the sound, high enough that a
    /// 16 ms scheduling hiccup does not under-run.
    static let targetFill = 0.22

    private let engine = AVAudioEngine()
    private let ring: OpaquePointer
    private let sampleRate: Double
    private var sourceNode: AVAudioSourceNode?
    private var scratchFrames: UnsafeMutablePointer<Int16>
    private let scratchCapacityFrames: Int
    private var isRunning = false

    /// Written by the real-time thread, read by nothing: it carries the tail of
    /// the last real sample so an under-run ramps to zero rather than jumping.
    private var tailLeft: Float = 0
    private var tailRight: Float = 0
    private var silentFramesRemaining = 0

    private let log = Logger(subsystem: "dev.nikan.earthbound", category: "audio")

    init(ring: OpaquePointer, sampleRate: Double) {
        self.ring = ring
        self.sampleRate = sampleRate > 1000 ? sampleRate : 32_040

        // Sized for the largest render quantum we can plausibly be handed, with
        // room to spare. 16k frames is ~0.5 s at the core's rate.
        scratchCapacityFrames = 16_384
        scratchFrames = .allocate(capacity: scratchCapacityFrames * 2)
        scratchFrames.initialize(repeating: 0, count: scratchCapacityFrames * 2)
    }

    deinit {
        scratchFrames.deallocate()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        // Ask for a small IO buffer. iOS treats it as a hint, but when it is
        // honoured it takes a large bite out of touch-to-sound latency.
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 2,
                                   interleaved: false)!
        let node = AVAudioSourceNode(format: format) { [self] _, _, frameCount, audioBufferList in
            render(frameCount: frameCount, into: audioBufferList)
        }
        sourceNode = node

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        isRunning = true

        observeSystemEvents()
        log.info("audio started at \(self.sampleRate, format: .fixed(precision: 1)) Hz")
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 0…1, applied by the mixer rather than in the render block so a slider drag
    /// never touches the real-time path.
    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = max(0, min(1, newValue)) }
    }

    // MARK: - Real-time render

    private func render(frameCount: AVAudioFrameCount,
                        into audioBufferList: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let frames = min(Int(frameCount), scratchCapacityFrames)

        let bytesWanted = frames * 2 * MemoryLayout<Int16>.size
        let bytesRead = eb_ring_read(ring, scratchFrames, bytesWanted)
        let framesRead = bytesRead / (2 * MemoryLayout<Int16>.size)

        let left = buffers.count > 0 ? buffers[0].mData?.assumingMemoryBound(to: Float.self) : nil
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil

        guard let left, let right else { return noErr }

        let scale: Float = 1.0 / 32_768.0
        for frame in 0..<framesRead {
            left[frame] = Float(scratchFrames[frame * 2]) * scale
            right[frame] = Float(scratchFrames[frame * 2 + 1]) * scale
        }
        tailLeft = framesRead > 0 ? left[framesRead - 1] : tailLeft
        tailRight = framesRead > 0 ? right[framesRead - 1] : tailRight

        if framesRead < frames {
            // Under-run. Ramp the last real sample down over a millisecond or so,
            // then sit at silence. A hard cut here is audible as a click on every
            // buffer boundary, which at 5 ms buffers is a constant rattle.
            let fadeFrames = min(frames - framesRead, Int(sampleRate * 0.001) + 1)
            for frame in framesRead..<(framesRead + fadeFrames) {
                let progress = Float(frame - framesRead) / Float(max(fadeFrames, 1))
                left[frame] = tailLeft * (1 - progress)
                right[frame] = tailRight * (1 - progress)
            }
            for frame in (framesRead + fadeFrames)..<frames {
                left[frame] = 0
                right[frame] = 0
            }
            silentFramesRemaining = 0
        }

        return noErr
    }

    // MARK: - System interruptions

    private func observeSystemEvents() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] notification in
            guard let self else { return }
            let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard let type = typeValue.flatMap(AVAudioSession.InterruptionType.init) else { return }
            switch type {
            case .began:
                self.engine.pause()
            case .ended:
                try? self.engine.start()
            @unknown default:
                break
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] _ in
            // Switching to headphones mid-game invalidates the engine's
            // connection to the old route; restarting is cheaper than trying to
            // rebuild just the affected node.
            guard let self, self.isRunning else { return }
            self.engine.pause()
            try? self.engine.start()
        }
    }
}
