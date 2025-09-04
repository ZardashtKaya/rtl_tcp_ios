//
//  NFMDemodulator.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation
import Accelerate

class NFMDemodulator: Demodulator {
    
    // MARK: - Properties
    private var bandwidthHz: Double = 12_500.0
    private var sampleRateHz: Double = 2_048_000.0
    private var squelchLevel: Float = 0.001
    
    // State for the demodulation algorithm
    private var lastI: Float = 0.0
    private var lastQ: Float = 0.0

    // MARK: - Public API
    
    func update(bandwidthHz: Double, sampleRateHz: Double, squelchLevel: Float) {
        self.bandwidthHz = bandwidthHz
        self.sampleRateHz = sampleRateHz
        // Scale the 0-1 UI squelch level to a power value. This may need tuning.
        self.squelchLevel = powf(squelchLevel, 2) * 0.01
    }

    func demodulate(iqSamples: [Float]) -> [Float] {
        // --- STEP 1: Low-Pass Filter and Decimate ---
        // We'll use a simple multi-stage decimation to get closer to our audio sample rate.
        let decimationFactor1 = 4
        let decimationFactor2 = 5
        let decimationFactor3 = 2
        let totalDecimation = decimationFactor1 * decimationFactor2 * decimationFactor3
        let finalSampleRate = self.sampleRateHz / Double(totalDecimation)
        
        // A proper implementation would have a real low-pass filter here.
        let filteredIQ = lowPassFilter(input: iqSamples)
        
        let decimated1 = decimate(input: filteredIQ, factor: decimationFactor1)
        let decimated2 = decimate(input: decimated1, factor: decimationFactor2)
        let finalIQ = decimate(input: decimated2, factor: decimationFactor3)
        
        let sampleCount = finalIQ.count / 2
        
        // --- STEP 2: Squelch ---
        var power: Float = 0.0
        vDSP_rmsqv(finalIQ, 1, &power, vDSP_Length(finalIQ.count))
        
        guard power > self.squelchLevel else {
            // Return silence if the signal is too weak.
            return [Float](repeating: 0.0, count: sampleCount)
        }
        
        // --- STEP 3: NFM Demodulation (Polar Discriminator) ---
        var demodulatedAudio = [Float](repeating: 0.0, count: sampleCount)
        
        for i in 0..<sampleCount {
            let I = finalIQ[i * 2]
            let Q = finalIQ[i * 2 + 1]
            
            // Multiply current sample by the conjugate of the previous sample
            // z[n] * conj(z[n-1])
            let real_part = (I * lastI) - (Q * -lastQ)
            let imag_part = (I * -lastQ) + (Q * lastI)
            
            // The phase of the result is the frequency deviation, which is our audio signal.
            demodulatedAudio[i] = atan2f(imag_part, real_part)
            
            // Store the current sample for the next iteration.
            lastI = I
            lastQ = Q
        }
        
        // --- STEP 4: Resample (Skipped for now) ---
        // A proper implementation would resample from `finalSampleRate` to the audio hardware rate.
        
        return demodulatedAudio
    }
    
    // MARK: - Private DSP Helpers
    
    private func decimate(input: [Float], factor: Int) -> [Float] {
        let outputCount = input.count / (factor * 2)
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0.0, count: outputCount * 2)
        for i in 0..<outputCount {
            output[i * 2] = input[i * factor * 2]
            output[i * 2 + 1] = input[i * factor * 2 + 1]
        }
        return output
    }
    
    private func lowPassFilter(input: [Float]) -> [Float] {
        // Placeholder for a real FIR filter.
        return input
    }
}
