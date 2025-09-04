//
//  Demodulator.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation

// Defines the interface for any demodulator.
protocol Demodulator {
    // The main function that takes I/Q data and returns audio samples.
    func demodulate(iqSamples: [Float]) -> [Float]
    
    // Allows the DSPEngine to configure the demodulator's parameters.
    func update(bandwidthHz: Double, sampleRateHz: Double, squelchLevel: Float)
}
