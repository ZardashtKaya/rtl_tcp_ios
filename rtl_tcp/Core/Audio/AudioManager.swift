//
//  AudioManager.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation
import AVFoundation

class AudioManager {
    // The target sample rate for the device's audio hardware.
    public static let audioSampleRate: Double = 48000.0

    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    // The format of the raw audio samples we will be generating.
    private let audioFormat: AVAudioFormat

    init() {
        // Standard PCM audio format: 48kHz sample rate, 32-bit floating point, single channel (mono).
        self.audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioManager.audioSampleRate,
                                         channels: 1,
                                         interleaved: false)!
        
        // Attach the player node to the audio engine.
        audioEngine.attach(playerNode)
        
        // Connect the player node to the engine's main output mixer.
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        // Prepare and start the engine.
        do {
            try audioEngine.start()
            playerNode.play()
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
        }
    }

    // This is the main entry point for the DSPEngine to send us audio data.
    public func playSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        // Create an AVAudioPCMBuffer to hold our samples.
        let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = buffer.frameCapacity
        
        // Get a pointer to the buffer's memory and copy our samples into it.
        let channelData = buffer.floatChannelData![0]
        memcpy(channelData, samples, samples.count * MemoryLayout<Float>.size)
        
        // Schedule the buffer for playback.
        playerNode.scheduleBuffer(buffer)
    }
}
