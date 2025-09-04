//
//  TuningIndicator.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

struct TuningIndicatorView: View {
    let tuningOffset: CGFloat
    
    // ----> CHANGE #1: Properties now use frequency values <----
    let bandwidthHz: Double
    let sampleRateHz: Double
    
    var body: some View {
        GeometryReader { geometry in
            // ----> CHANGE #2: Calculate the bandwidth as a percentage of the view <----
            // The percentage of the screen the bandwidth occupies is bandwidthHz / sampleRateHz
            let bandwidthPercentage = bandwidthHz / sampleRateHz
            let bandwidthPixels = geometry.size.width * CGFloat(bandwidthPercentage)
            
            let centerX = geometry.size.width * tuningOffset
            
            // The rest of the drawing logic is now correct
            Rectangle()
                .fill(Color.red.opacity(0.2))
                .frame(width: bandwidthPixels, height: geometry.size.height)
                .position(x: centerX, y: geometry.size.height / 2)
            
            Path { path in
                path.move(to: CGPoint(x: centerX, y: 0))
                path.addLine(to: CGPoint(x: centerX, y: geometry.size.height))
            }
            .stroke(Color.red, lineWidth: 2)
        }
    }
}
