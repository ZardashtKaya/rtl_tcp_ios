//
//  Features/Radio/View/Controls/TuningControlsView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

struct TuningControlsView: View {
    @Binding var squelchLevel: Float
    @Binding var frequencyMHz: Double
    @Binding var frequencyStep: FrequencyStep
    @FocusState.Binding var isFrequencyFieldFocused: Bool
    @Binding var vfoBandwidthHz: Double
    var viewModel: RadioViewModel?
    
    private func generateTestTone(frequency: Double, duration: Double, sampleRate: Double) -> [Float] {
            let sampleCount = Int(duration * sampleRate)
            var samples = [Float](repeating: 0.0, count: sampleCount)
            
            for i in 0..<sampleCount {
                let time = Double(i) / sampleRate
                samples[i] = Float(0.3 * sin(2.0 * .pi * frequency * time))
            }
            
            return samples
        }
    
    private func playTestTone() {
            let testTone = generateTestTone(frequency: 440.0, duration: 1.0, sampleRate: 48000.0)
            
            // For now, just print - we'll need to access the audio manager through the view model
            print("🔊 Generated test tone with \(testTone.count) samples")
            
            // If viewModel is available, play the test tone
            viewModel?.playTestAudio(testTone)
        }
   
    
    var body: some View {
        Form {
            Section(header: Text("Center Frequency: \(String(format: "%.4f", frequencyMHz)) MHz")) {
                FrequencyDialView(frequencyMHz: $frequencyMHz, step: $frequencyStep)
            }
            Section(header: Text("Audio Debug")) {
                Button("Test Audio") {
                    playTestTone()
                }
                
                Button("Test Demodulation") {
                    viewModel?.testDemodulation()
                }
                
                Button("Disable Squelch") {
                    viewModel?.squelchLevel = 0.0
                }
                
                if let viewModel = viewModel {
                    Button("Audio Stats") {
                        viewModel.getAudioStats()
                    }
                }
            }
            
            Section(header: Text("VFO")) {
                            // ----> ADD BANDWIDTH DISPLAY <----
                            HStack {
                                Text("Bandwidth")
                                Spacer()
                                // Format the value in KHz for readability
                                Text("\(String(format: "%.1f", vfoBandwidthHz / 1000)) KHz")
                                    .foregroundColor(.gray)
                            }
                            
                            HStack {
                                Image(systemName: "speaker.slash.fill")
                                Slider(value: $squelchLevel, in: 0.0...1.0)
                            }
                        }
                    }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFrequencyFieldFocused = false }
            }
        }
    }
    
    
    private func generateAndPlayTestTone() {
        let testTone = generateTestTone(frequency: 440.0, duration: 1.0, sampleRate: 48000.0)
        
        // Access audio manager through view model
        // You'll need to expose the audio manager in your view model:
        // viewModel.playTestAudio(testTone)
        
        print("🔊 Generated test tone with \(testTone.count) samples")
    }
}
