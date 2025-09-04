//
//  UI Components/SpectrogramView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

struct SpectrogramView: View { // Or WaterfallView
    let data: [Float] // Or [[Float]] for WaterfallView
    
    // ----> CHANGE THIS SECTION <----
    // Remove the hardcoded values and accept them from the parent.
    let minDb: Float
    let maxDb: Float
    // -----------------------------


    var body: some View {
        // The Canvas is a high-performance drawing surface.
        Canvas { context, size in
            guard data.count > 1 else { return }

            let width = size.width
            let height = size.height
            let step = width / Double(data.count - 1)
            let dbRange = maxDb - minDb
            
            var path = Path()
            // Start the path at the first data point.
            let firstY = 1.0 - ( (data[0] - minDb) / dbRange )
            path.move(to: CGPoint(x: 0, y: height * Double(firstY)))
            
            // Loop through the rest of the data points to draw the line.
            for i in 1..<data.count {
                let y = 1.0 - ( (data[i] - minDb) / dbRange )
                
                // Clamp the y-coordinate to prevent drawing outside the view bounds.
                let clampedY = max(0.0, min(1.0, y))
                
                path.addLine(to: CGPoint(x: Double(i) * step, y: height * Double(clampedY)))
            }
            
            // Stroke the path with a color and style.
            context.stroke(path, with: .color(.green), lineWidth: 1.5)
        }
    }
}
