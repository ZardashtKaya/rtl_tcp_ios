//
//  UI Components/WaterfallView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

struct WaterfallView: View {
    let data: [[Float]]
    let minDb: Float
    let maxDb: Float
    
    // The pre-computed Color Look-Up Table
    private let colorMap: [(r: UInt8, g: UInt8, b: UInt8)]

    init(data: [[Float]], minDb: Float, maxDb: Float) {
        self.data = data
        self.minDb = minDb
        self.maxDb = maxDb
        
        // Pre-compute 256 colors only ONCE.
        var map = [(r: UInt8, g: UInt8, b: UInt8)]()
        for i in 0..<256 {
            let value = Float(i) / 255.0
            map.append(Self.colorFor(value: value))
        }
        self.colorMap = map
    }

    var body: some View {
        GeometryReader { geometry in
            if let image = makeImage(size: geometry.size) {
                Image(image, scale: 1.0, label: Text("Waterfall"))
                    .interpolation(.none).resizable()
            }
        }
    }
    
    private func makeImage(size: CGSize) -> CGImage? {
        guard !data.isEmpty, let firstRow = data.first, !firstRow.isEmpty else { return nil }
        
        let height = data.count
        let width = firstRow.count
        let dbRange = maxDb - minDb
        
        var pixelData = [UInt8](repeating: 0, count: width * height * 4)
        
        for y in 0..<height {
            for x in 0..<width {
                let dbValue = data[y][x]
                let normalized = (dbValue - minDb) / dbRange
                
                // ----> THE OPTIMIZATION <----
                // Use a fast integer lookup instead of expensive calculations.
                let colorIndex = Int(max(0.0, min(1.0, normalized)) * 255.0)
                let color = colorMap[colorIndex]
                
                let index = (y * width + x) * 4
                pixelData[index] = color.r
                pixelData[index + 1] = color.g
                pixelData[index + 2] = color.b
                pixelData[index + 3] = 255
            }
        }
        
        let provider = CGDataProvider(data: Data(pixelData) as CFData)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
    
    // This is only called 256 times now.
    private static func colorFor(value: Float) -> (r: UInt8, g: UInt8, b: UInt8) {
        // ... color gradient logic is the same ...
        if value < 0.25 { let t = value / 0.25; return (r: 0, g: UInt8(t * 255), b: 255) }
        else if value < 0.5 { let t = (value - 0.25) / 0.25; return (r: 0, g: 255, b: UInt8((1 - t) * 255)) }
        else if value < 0.75 { let t = (value - 0.5) / 0.25; return (r: UInt8(t * 255), g: 255, b: 0) }
        else { let t = (value - 0.75) / 0.25; return (r: 255, g: UInt8((1 - t) * 255), b: 0) }
    }
}
