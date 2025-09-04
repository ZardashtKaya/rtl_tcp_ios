//
//  Core/DSP/Demodulators/NFMDemodulator.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation
import Accelerate

class NFMDemodulator: Demodulator {
    
    // MARK: - Properties
    private var squelchLevel: Float = 0.001
    private var lastI: Float = 0.0
    private var lastQ: Float = 0.0
    
    private var firFilter: [Float] = []
    private var resamplerInputBuffer: [Float] = []
    private var resamplerRatio: Double = 1.0
    
    // Reusable processing buffers
    private var filteredBuffer: [Float] = []
    private var decimatedBuffer: [Float] = []
    private var demodulatedBuffer: [Float] = []
    private var realInput: [Float] = []
    private var imagInput: [Float] = []
    private var realOutput: [Float] = []
    private var imagOutput: [Float] = []
    
    // ----> ADD: Debug counters <----
    private var processedChunks: Int = 0
    private var squelchedChunks: Int = 0

    // MARK: - Public API
    
    func update(bandwidthHz: Double, sampleRateHz: Double, squelchLevel: Float) {
        self.squelchLevel = powf(squelchLevel, 2) * 0.01
        
        let audioBandwidth = 8000.0
        self.firFilter = designLowPassFIR(sampleRate: sampleRateHz, cutoffFrequency: audioBandwidth, length: 65)
        
        // ----> FIX: Much more conservative decimation <----
        // Instead of decimating to 40kHz, let's decimate to a higher intermediate rate
        let targetIntermediateRate = 200000.0 // 200kHz instead of 40kHz
        let decimationFactor = max(1, Int(floor(sampleRateHz / targetIntermediateRate)))
        let intermediateSampleRate = sampleRateHz / Double(decimationFactor)
        self.resamplerRatio = AudioManager.audioSampleRate / intermediateSampleRate
        
        print("🎛️ NFM Demodulator updated:")
        print("   Sample Rate: \(sampleRateHz) Hz")
        print("   Bandwidth: \(bandwidthHz) Hz")
        print("   Squelch: \(squelchLevel)")
        print("   Decimation: \(decimationFactor)")
        print("   Intermediate SR: \(intermediateSampleRate) Hz")
        print("   Resample Ratio: \(resamplerRatio)")
        
        // Pre-allocate buffers
        let maxSamples = 8192
        filteredBuffer = [Float](repeating: 0.0, count: maxSamples)
        decimatedBuffer = [Float](repeating: 0.0, count: maxSamples)
        demodulatedBuffer = [Float](repeating: 0.0, count: maxSamples / 2)
        realInput = [Float](repeating: 0.0, count: maxSamples / 2)
        imagInput = [Float](repeating: 0.0, count: maxSamples / 2)
        realOutput = [Float](repeating: 0.0, count: maxSamples / 2)
        imagOutput = [Float](repeating: 0.0, count: maxSamples / 2)
    }

    func demodulate(frequencyBand iqSamples: [Float]) -> [Float] {
        guard !firFilter.isEmpty, !iqSamples.isEmpty else {
            print("⚠️ Demodulator not ready: filter=\(firFilter.isEmpty), samples=\(iqSamples.isEmpty)")
            return []
        }

        processedChunks += 1
        
        if iqSamples.count % 2 != 0 {
            print("⚠️ Odd number of IQ samples: \(iqSamples.count)")
            return []
        }
        
        if processedChunks % 100 == 0 {
            print("🎛️ NFM processing chunk \(processedChunks), input samples: \(iqSamples.count)")
        }

        let filteredIQ = applyFIROptimized(input: iqSamples)
        
        // ----> FIX: Use the same decimation factor calculation as in update() <----
        let targetIntermediateRate = 200000.0
        let decimationFactor = max(1, Int(floor(2_048_000.0 / targetIntermediateRate)))
        
        let decimatedIQ = decimateOptimized(input: filteredIQ, factor: decimationFactor)
        
        let sampleCount = decimatedIQ.count / 2
        guard sampleCount > 0 else {
            print("⚠️ No samples after decimation: input=\(filteredIQ.count), decimated=\(decimatedIQ.count)")
            return []
        }
        
        // Squelch check using vDSP
        var power: Float = 0.0
        vDSP_rmsqv(decimatedIQ, 1, &power, vDSP_Length(decimatedIQ.count))
        
        if power <= self.squelchLevel {
            squelchedChunks += 1
            if squelchedChunks % 100 == 0 {
                print("🔇 Squelched \(squelchedChunks) chunks (power: \(power), threshold: \(squelchLevel))")
            }
            return resampleOptimized(input: [Float](repeating: 0.0, count: sampleCount))
        }
        
        let demodulatedAudio = demodulateNFMOptimized(decimatedIQ, sampleCount: sampleCount)
        let resampledAudio = resampleOptimized(input: demodulatedAudio)
        
        if processedChunks % 100 == 0 {
            let audioLevel = resampledAudio.isEmpty ? 0.0 : vDSP.rootMeanSquare(resampledAudio)
            print("🎵 NFM output: power=\(power), demod_samples=\(demodulatedAudio.count), resampled=\(resampledAudio.count), level=\(audioLevel)")
        }
        
        return resampledAudio
    }
    
    // MARK: - Optimized Private Methods
    
    private func decimateOptimized(input: [Float], factor: Int) -> [Float] {
        let inputSampleCount = input.count / 2
        let outputSampleCount = inputSampleCount / factor
        
        // ----> ADD: Debug decimation <----
        if processedChunks % 100 == 0 {
            print("🔧 Decimation: input=\(input.count) samples (\(inputSampleCount) IQ), factor=\(factor), output=\(outputSampleCount) IQ")
        }
        
        guard outputSampleCount > 0 else {
            print("⚠️ Decimation would produce 0 samples: input=\(inputSampleCount), factor=\(factor)")
            return []
        }
        
        if decimatedBuffer.count < outputSampleCount * 2 {
            decimatedBuffer = [Float](repeating: 0.0, count: outputSampleCount * 2)
        }
        
        // Vectorized decimation
        for i in 0..<outputSampleCount {
            let inputIndex = i * factor
            if inputIndex * 2 + 1 < input.count {
                decimatedBuffer[i * 2] = input[inputIndex * 2]
                decimatedBuffer[i * 2 + 1] = input[inputIndex * 2 + 1]
            }
        }
        
        return Array(decimatedBuffer.prefix(outputSampleCount * 2))
    }
    
    
    private func demodulateNFMOptimized(_ decimatedIQ: [Float], sampleCount: Int) -> [Float] {
        if demodulatedBuffer.count < sampleCount {
            demodulatedBuffer = [Float](repeating: 0.0, count: sampleCount)
        }
        
        for i in 0..<sampleCount {
            let I = decimatedIQ[i * 2]
            let Q = decimatedIQ[i * 2 + 1]
            
            // FM demodulation using phase difference
            let currentPhase = atan2f(Q, I)
            
            if i == 0 {
                // For the first sample, use the stored last phase
                let phaseDiff = currentPhase - atan2f(lastQ, lastI)
                demodulatedBuffer[i] = phaseDiff * 0.159155 // 1/(2*pi) for normalization
            } else {
                // Use previous sample's phase
                let prevPhase = atan2f(decimatedIQ[(i-1) * 2 + 1], decimatedIQ[(i-1) * 2])
                var phaseDiff = currentPhase - prevPhase
                
                // Unwrap phase difference
                while phaseDiff > Float.pi { phaseDiff -= 2 * Float.pi }
                while phaseDiff < -Float.pi { phaseDiff += 2 * Float.pi }
                
                demodulatedBuffer[i] = phaseDiff * 0.159155 // 1/(2*pi)
            }
            
            lastI = I
            lastQ = Q
        }
        
        return Array(demodulatedBuffer.prefix(sampleCount))
    }

    private func designLowPassFIR(sampleRate: Double, cutoffFrequency: Double, length: Int) -> [Float] {
        let fc = Float(cutoffFrequency / sampleRate)
        let M = Float(length - 1)
        var kernel = [Float](repeating: 0, count: length)
        
        for i in 0..<length {
            let n = Float(i) - M / 2.0
            if n == 0.0 {
                kernel[i] = 2.0 * fc
            } else {
                kernel[i] = sin(2.0 * .pi * fc * n) / (.pi * n)
            }
            // Blackman window
            kernel[i] *= 0.42 - 0.5 * cos(2.0 * .pi * Float(i) / M) + 0.08 * cos(4.0 * .pi * Float(i) / M)
        }
        
        // Normalize
        let sum = kernel.reduce(0, +)
        if sum > 0 {
            vDSP.divide(kernel, sum, result: &kernel)
        }
        
        return kernel
    }

    private func applyFIROptimized(input: [Float]) -> [Float] {
        let inputCount = input.count / 2
        
        if filteredBuffer.count < input.count {
            filteredBuffer = [Float](repeating: 0.0, count: input.count)
        }
        
        if realInput.count < inputCount {
            realInput = [Float](repeating: 0.0, count: inputCount)
            imagInput = [Float](repeating: 0.0, count: inputCount)
            realOutput = [Float](repeating: 0.0, count: inputCount)
            imagOutput = [Float](repeating: 0.0, count: inputCount)
        }
        
        // Deinterleave
        for i in 0..<inputCount {
            realInput[i] = input[i * 2]
            imagInput[i] = input[i * 2 + 1]
        }
        
        // Apply convolution
        vDSP_conv(realInput, 1, firFilter.reversed(), 1, &realOutput, 1, vDSP_Length(inputCount), vDSP_Length(firFilter.count))
        vDSP_conv(imagInput, 1, firFilter.reversed(), 1, &imagOutput, 1, vDSP_Length(inputCount), vDSP_Length(firFilter.count))
        
        // Interleave output
        for i in 0..<inputCount {
            filteredBuffer[i * 2] = realOutput[i]
            filteredBuffer[i * 2 + 1] = imagOutput[i]
        }
        
        return Array(filteredBuffer.prefix(input.count))
    }
    
    private func resampleOptimized(input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        
        resamplerInputBuffer.append(contentsOf: input)
        var output = [Float]()
        output.reserveCapacity(Int(Double(input.count) * resamplerRatio) + 100)
        
        var outputSamplePosition = 0.0
        let inputCount = Double(resamplerInputBuffer.count)
        
        while outputSamplePosition < inputCount - 1 && outputSamplePosition >= 0 {
            let index = Int(floor(outputSamplePosition))
            
            guard index >= 0 && index + 1 < resamplerInputBuffer.count else {
                break
            }
            
            let frac = Float(outputSamplePosition.truncatingRemainder(dividingBy: 1.0))
            
            let y0 = resamplerInputBuffer[index]
            let y1 = resamplerInputBuffer[index + 1]
            
            let interpolatedSample = y0 + frac * (y1 - y0)
            output.append(interpolatedSample)
            
            outputSamplePosition += 1.0 / resamplerRatio
        }
        
        let consumedSamples = Int(floor(outputSamplePosition))
        if consumedSamples > 0 && consumedSamples <= resamplerInputBuffer.count {
            resamplerInputBuffer.removeFirst(consumedSamples)
        } else if consumedSamples > resamplerInputBuffer.count {
            resamplerInputBuffer.removeAll(keepingCapacity: true)
        }
        
        return output
    }
}
