//
//  Core/Audio/rtl_tcpApp.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation
import AVFoundation

class AudioManager {
    public static let audioSampleRate: Double = 48000.0

    private let audioEngine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    
    // A circular buffer to safely pass audio from the DSP thread to the audio thread.
    // Size is 2 seconds of audio data to prevent buffer underruns.
    private let audioBuffer = CircularBuffer(size: Int(audioSampleRate * 2))

    private let audioFormat: AVAudioFormat

    init() {
        self.audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioManager.audioSampleRate,
                                         channels: 1,
                                         interleaved: false)!
        
        // Create the source node. Its render block will be called by the audio engine
        // whenever it needs more audio samples.
        self.sourceNode = AVAudioSourceNode(format: self.audioFormat) { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            
            // Get a pointer to the output buffer
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            
            // Read the requested number of samples from our circular buffer
            let samples = self.audioBuffer.read(count: Int(frameCount))
            
            // Copy the samples into the output buffer
            for frame in 0..<Int(frameCount) {
                if frame < samples.count {
                    let value = samples[frame]
                    for buffer in ablPointer {
                        let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                        buf[frame] = value
                    }
                } else {
                    // If we run out of samples (buffer underrun), fill the rest with silence.
                    for buffer in ablPointer {
                        let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                        buf[frame] = 0.0
                    }
                }
            }
            return noErr
        }
        
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        do {
            try audioEngine.start()
        } catch {
            print("Error starting audio engine: \(error.localizedDescription)")
        }
    }

    /// Receives audio samples from the DSPEngine and writes them to the circular buffer.
    public func playSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        audioBuffer.write(samples)
    }
}
