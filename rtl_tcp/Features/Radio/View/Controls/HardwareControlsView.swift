//
//  HardwareControlsView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

struct HardwareControlsView: View {
    @Binding var settings: RadioSettings
    @Binding var selectedSampleRate: SampleRate
    
    private let fftSizes = [1024, 2048, 4096, 8192] // This can be moved to a model if preferred
    
    var body: some View {
        Form {
            Section(header: Text("Gain")) {
                Toggle("AGC (Automatic Gain Control)", isOn: $settings.isAgcOn)
                
                HStack {
                    Text("Tuner Gain")
                    Slider(
                        value: Binding(
                            get: { Double(settings.tunerGainIndex) },
                            set: { settings.tunerGainIndex = Int($0) }
                        ),
                        in: 0...28,
                        step: 1
                    )
                }
                .disabled(settings.isAgcOn)
                .foregroundColor(settings.isAgcOn ? .gray : .primary)
            }
            
            Section(header: Text("Device")) {
                Picker("Sample Rate", selection: $selectedSampleRate) {
                    ForEach(SampleRate.allCases) { rate in
                        Text(rate.stringValue).tag(rate)
                    }
                }
                
                Toggle("Bias Tee", isOn: $settings.isBiasTeeOn)
                Toggle("Offset Tuning", isOn: $settings.isOffsetTuningOn)
            }
        }
    }
}
