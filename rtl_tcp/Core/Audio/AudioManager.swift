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
    
    private var samplesReceived: Int = 0
    private var samplesPlayed: Int = 0
    private var bufferUnderruns: Int = 0

    init() {
        self.audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: AudioManager.audioSampleRate,
                                         channels: 2,
                                         interleaved: false)!
        
        setupAudioEngine()
    }
    
    // ----> ADD: Reset method for connection initialization <----
    public func resetForConnection() {
        print("🔊 Resetting audio system for new connection...")
        
        // Reset counters
        samplesReceived = 0
        samplesPlayed = 0
        bufferUnderruns = 0
        
        // Reset the circular buffer
        audioBuffer.reset()
        
        // Restart audio engine if needed
        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
                print("🔊 Audio engine restarted")
            } catch {
                print("❌ Failed to restart audio engine: \(error)")
            }
        }
        
        print("🔊 Audio system reset complete")
    }
    
    // ----> ADD: Stop method for disconnection <----
    public func stopForDisconnection() {
        print("🔊 Stopping audio system for disconnection...")
        
        // Clear the buffer
        audioBuffer.reset()
        
        // Stop the audio engine
        if audioEngine.isRunning {
            audioEngine.stop()
            print("🔊 Audio engine stopped")
        }
    }
    
    private func setupAudioEngine() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetooth])
            try audioSession.setActive(true)
            print("🔊 Audio session configured successfully")
        } catch {
            print("❌ Audio session setup failed: \(error)")
            do {
                try AVAudioSession.sharedInstance().setCategory(.playback)
                try AVAudioSession.sharedInstance().setActive(true)
                print("🔊 Audio session configured with fallback")
            } catch {
                print("❌ Fallback audio session setup also failed: \(error)")
            }
        }
        
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
            
            for frame in 0..<Int(frameCount) {
                let value: Float = frame < samples.count ? max(-1.0, min(1.0, samples[frame])) : 0.0
                
                for buffer in ablPointer {
                    let buf = buffer.mData!.assumingMemoryBound(to: Float.self)
                    buf[frame] = value
                }
            }
            return noErr
        }
        
        audioEngine.attach(sourceNode)
        audioEngine.connect(sourceNode, to: audioEngine.mainMixerNode, format: audioFormat)
        
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

    public func playSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        
        samplesReceived += samples.count
        
        if samplesReceived % Int(AudioManager.audioSampleRate * 10) == 0 {
            print("🔊 Audio stats: received \(samplesReceived), played \(samplesPlayed), buffer: \(audioBuffer.availableForReading), underruns: \(bufferUnderruns)")
        }
        
        let hasInvalidSamples = samples.contains { !$0.isFinite }
        if hasInvalidSamples {
            print("⚠️ Invalid audio samples detected (NaN/Inf)")
            let cleanSamples = samples.map { $0.isFinite ? $0 : 0.0 }
            audioBuffer.write(cleanSamples)
        } else {
            audioBuffer.write(samples)
        }
    }
    
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
