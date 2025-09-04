//
//  Core/Audio/AudioManager.swift
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
    private let audioBuffer = CircularBuffer(size: Int(audioSampleRate * 2))
    private let audioFormat: AVAudioFormat
    
    // ----> ADD: Debug counters <----
    private var samplesReceived: Int = 0
    private var samplesPlayed: Int = 0
    private var bufferUnderruns: Int = 0

    init() {
        // Change to stereo to match the main mixer
        self.audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioManager.audioSampleRate,
                                         channels: 2,  // Changed from 1 to 2
                                         interleaved: false)!
        
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth])
            try audioSession.setActive(true)
            print("🔊 Audio session configured successfully")
        } catch {
            print("❌ Audio session setup failed: \(error)")
            // Try fallback configuration
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                print("🔊 Audio session configured with fallback")
            } catch {
                print("❌ Fallback audio session setup also failed: \(error)")
            }
        }
        
        // Create the source node
        self.sourceNode = AVAudioSourceNode(format: self.audioFormat) { [unowned self] _, _, frameCount, audioBufferList -> OSStatus in
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let samples = self.audioBuffer.read(count: Int(frameCount))
            
            if samples.count < Int(frameCount) {
                self.bufferUnderruns += 1
                if self.bufferUnderruns % 100 == 0 {
                    print("⚠️ Audio buffer underrun #\(self.bufferUnderruns): requested \(frameCount), got \(samples.count)")
                }
            }
            
            self.samplesPlayed += samples.count
            
            // Fill both channels with the same mono data
            for frame in 0..<Int(frameCount) {
                let value: Float = frame < samples.count ? max(-1.0, min(1.0, samples[frame])) : 0.0
                
                // Write to both left and right channels
                for buffer in ablPointer {
                    let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                    buf[frame] = value
                }
            }
            return noErr
        }
        
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
        // ----> ADD: More detailed error handling <----
        do {
            try audioEngine.start()
            print("🔊 Audio engine started successfully")
            print("🔊 Audio format: \(audioFormat)")
            print("🔊 Main mixer node format: \(audioEngine.mainMixerNode.outputFormat(forBus: 0))")
        } catch {
            print("❌ Error starting audio engine: \(error)")
            print("❌ Audio engine description: \(audioEngine)")
        }
    }

    /// Receives audio samples from the DSPEngine and writes them to the circular buffer.
    public func playSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        
        samplesReceived += samples.count
        
        // ----> ADD: Debug logging every 10 seconds worth of samples <----
        if samplesReceived % Int(AudioManager.audioSampleRate * 10) == 0 {
            print("🔊 Audio stats: received \(samplesReceived), played \(samplesPlayed), buffer: \(audioBuffer.availableForReading), underruns: \(bufferUnderruns)")
        }
        
        // ----> ADD: Check for NaN or infinite values <----
        let hasInvalidSamples = samples.contains { !$0.isFinite }
        if hasInvalidSamples {
            print("⚠️ Invalid audio samples detected (NaN/Inf)")
            let cleanSamples = samples.map { $0.isFinite ? $0 : 0.0 }
            audioBuffer.write(cleanSamples)
        } else {
            audioBuffer.write(samples)
        }
    }
    
    // ----> ADD: Debug method <----
    public func getAudioStats() -> (received: Int, played: Int, buffered: Int, underruns: Int) {
        return (samplesReceived, samplesPlayed, audioBuffer.availableForReading, bufferUnderruns)
    }
    public func debugAudioPipeline() {
        let stats = getAudioStats()
        let bufferLevel = Double(stats.buffered) / AudioManager.audioSampleRate
        
        print("🔊 Audio Pipeline Debug:")
        print("   Received: \(stats.received) samples")
        print("   Played: \(stats.played) samples")
        print("   Buffered: \(stats.buffered) samples (\(String(format: "%.2f", bufferLevel))s)")
        print("   Underruns: \(stats.underruns)")
        print("   Engine running: \(audioEngine.isRunning)")
        print("   Source node format: \(sourceNode.outputFormat(forBus: 0))")
    }
}
