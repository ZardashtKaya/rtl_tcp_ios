//
//  Demodulator.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation

// Defines the interface for any demodulator.
protocol Demodulator {
    // The main function that takes a frequency band and returns audio samples.
    func demodulate(frequencyBand: [Float]) -> [Float]

    // Allows the DSPEngine to configure the demodulator's parameters.
    func update(bandwidthHz: Double, sampleRateHz: Double, squelchLevel: Float)
}
