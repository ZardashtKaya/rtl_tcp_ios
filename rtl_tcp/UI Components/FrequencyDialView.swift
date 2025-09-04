//
//  UI Components/FrequencyDialView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//


import SwiftUI

// FrequencyStep enum remains the same...
enum FrequencyStep: Double, CaseIterable, Identifiable {
    case hz1 = 1, hz10 = 10, hz100 = 100, khz1 = 1_000, khz10 = 10_000, khz100 = 100_000, mhz1 = 1_000_000, mhz10 = 10_000_000, mhz100 = 100_000_000
    var id: Double { self.rawValue }
    var stringValue: String {
        switch self {
        case .hz1: return "1 Hz"; case .hz10: return "10 Hz"; case .hz100: return "100 Hz"
        case .khz1: return "1 KHz"; case .khz10: return "10 KHz"; case .khz100: return "100 KHz"
        case .mhz1: return "1 MHz"; case .mhz10: return "10 MHz"; case .mhz100: return "100 MHz"
        }
    }
}


struct FrequencyDialView: View {
    @Binding var frequencyMHz: Double
    @Binding var step: FrequencyStep
    
    @State private var startDragFrequency: Double? = nil
    @GestureState private var dragTranslation: CGFloat = 0
    
    // ----> THE FIX: Define the two gestures as properties <----
    
    // This gesture detects the start of the drag to capture the initial frequency.
    var startDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                if self.startDragFrequency == nil {
                    self.startDragFrequency = self.frequencyMHz
                }
            }
    }
    
    // This gesture handles the live update and animation.
    var updateDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation.width
                
                if let startFreq = startDragFrequency {
                    let pixelPerHz = 0.05 // Sensitivity
                    let frequencyChangeHz = -value.translation.width * (1 / pixelPerHz) * step.rawValue
                    let frequencyChangeMHz = frequencyChangeHz / 1_000_000
                    
                    var newFrequency = startFreq + frequencyChangeMHz
                    newFrequency = max(0, min(1700, newFrequency))
                    
                    // Use DispatchQueue to avoid potential view update conflicts within a gesture
                    DispatchQueue.main.async {
                        self.frequencyMHz = newFrequency
                    }
                }
            }
            .onEnded { _ in
                self.startDragFrequency = nil
            }
    }
    
    var body: some View {
        VStack {
            Canvas { context, size in
                let center = size.width / 2
                
                var indicator = Path()
                indicator.move(to: CGPoint(x: center, y: 0))
                indicator.addLine(to: CGPoint(x: center, y: size.height * 0.6))
                context.stroke(indicator, with: .color(.red), lineWidth: 2)
                
                let tickCount = 40
                let spacing = size.width / CGFloat(tickCount)
                
                for i in 0...tickCount {
                    let x = (CGFloat(i) * spacing) + dragTranslation
                    let isMajorTick = i % 5 == 0
                    
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height * (isMajorTick ? 0.7 : 0.85)))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(.gray), lineWidth: 1)
                }
            }
            .frame(height: 50)
            // ----> THE FIX: Combine the gestures using SimultaneousGesture <----
            .gesture(
                updateDragGesture.simultaneously(with: startDragGesture)
            )
            
            Menu {
                // The Picker goes inside the Menu's content.
                // Using a Picker here ensures the binding and selection logic still works perfectly.
                Picker("Step Size", selection: $step) {
                    ForEach(FrequencyStep.allCases) { stepValue in
                        Text(stepValue.stringValue).tag(stepValue)
                    }
                    // We can add a divider and a custom option for the future
                    Divider()
                    Text("Custom...").tag(FrequencyStep.khz1) // Placeholder
                }
            } label: {
                // The "label" is what the user sees before tapping the menu.
                // It will be a button showing the currently selected step size.
                HStack {
                    Text("Step: \(step.stringValue)")
                    Image(systemName: "chevron.down")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.2))
                .cornerRadius(8)
            }
            .padding(.top, 5) // Add a little space above the menu button
        }
    }
}
