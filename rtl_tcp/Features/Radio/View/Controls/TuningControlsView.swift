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

    
    var body: some View {
        Form {
            Section(header: Text("Center Frequency: \(String(format: "%.4f", frequencyMHz)) MHz")) {
                FrequencyDialView(frequencyMHz: $frequencyMHz, step: $frequencyStep)
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
}
