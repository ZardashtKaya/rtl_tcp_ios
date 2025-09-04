//
//  DisplayControlsView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//
import SwiftUI

struct DSPControlsView: View {
    // Bindings for all DSP and Display parameters
    @Binding var isAutoScaleEnabled: Bool
    @Binding var manualMinDb: Float
    @Binding var manualMaxDb: Float
    @Binding var selectedFFTSize: Int
    @Binding var averagingCount: Int
    @Binding var waterfallHeight: Int
    
    // The constant now lives here, where it is used.
    private let fftSizes = [1024, 2048, 4096, 8192]

    var body: some View {
        Form {
            Section(header: Text("Display Scale")) {
                Toggle("Auto-Scale", isOn: $isAutoScaleEnabled)
                VStack {
                    Text("Max dB: \(Int(manualMaxDb))")
                    Slider(value: $manualMaxDb, in: -80...40, step: 1)
                    Text("Min dB: \(Int(manualMinDb))")
                    Slider(value: $manualMinDb, in: -120...0, step: 1)
                }
                .disabled(isAutoScaleEnabled)
                .foregroundColor(isAutoScaleEnabled ? .gray : .primary)
            }
            
            Section(header: Text("Processing Parameters")) {
                Picker("FFT Size", selection: $selectedFFTSize) {
                    ForEach(fftSizes, id: \.self) { size in
                        Text("\(size)").tag(size)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                
                Stepper("Averaging Count: \(averagingCount)", value: $averagingCount, in: 1...20)
                Stepper("Waterfall Height: \(waterfallHeight)", value: $waterfallHeight, in: 50...500, step: 10)
            }
        }
    }
}
