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
        print("🔊 Generated test tone with \(testTone.count) samples")
        viewModel?.playTestAudio(testTone)
    }
    
    // ----> ADD: Test spectrum update <----
    private func testSpectrumUpdate() {
        guard let viewModel = viewModel else { return }
        
        // Generate fake spectrum data
        let fftSize = 4096
        var fakeSpectrum = [Float](repeating: 0.0, count: fftSize)
        
        for i in 0..<fftSize {
            let freq = Float(i) / Float(fftSize)
            fakeSpectrum[i] = -80.0 + 40.0 * sin(freq * 20.0 * .pi) + Float.random(in: -10...10)
        }
        
        // Force update the spectrum
        DispatchQueue.main.async {
            viewModel.dspEngine.spectrum = fakeSpectrum
            print("📊 Injected fake spectrum data")
        }
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
                
                // ----> ADD: Test spectrum button <----
                Button("Test Spectrum Update") {
                    testSpectrumUpdate()
                }
                
                Button("Disable Squelch") {
                    viewModel?.squelchLevel = 0.0
                }
                
                if let viewModel = viewModel {
                    Button("Audio Stats") {
                        viewModel.getAudioStats()
                    }
                    
                    // ----> ADD: DSP Stats <----
                    Button("DSP Stats") {
                        print("📊 Spectrum count: \(viewModel.dspEngine.spectrum.count)")
                        print("📊 Waterfall count: \(viewModel.dspEngine.waterfallData.count)")
                        print("📊 Dynamic range: \(viewModel.dspEngine.dynamicMinDb) to \(viewModel.dspEngine.dynamicMaxDb)")
                    }
                }
            }
            
            Section(header: Text("VFO")) {
                HStack {
                    Text("Bandwidth")
                    Spacer()
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
}
