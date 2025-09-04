import Foundation
import Accelerate

class NFMDemodulator: Demodulator {
    
    // MARK: - Properties
    private var squelchLevel: Float = 0.001
    
    // State for the demodulation algorithm
    private var lastI: Float = 0.0
    private var lastQ: Float = 0.0
    
    // Low-Pass Filter coefficients
    private var firFilter: [Float] = []
    
    // Resampler state
    private var resamplerInputBuffer: [Float] = []
    private var resamplerRatio: Double = 1.0

    // MARK: - Public API
    
    func update(bandwidthHz: Double, sampleRateHz: Double, squelchLevel: Float) {
        self.squelchLevel = powf(squelchLevel, 2) * 0.01

        // Design the FIR Low-Pass Filter
        let audioBandwidth = 8000.0
        self.firFilter = designLowPassFIR(sampleRate: sampleRateHz, cutoffFrequency: audioBandwidth, length: 65)
        
        // Calculate Resampling Ratio
        let decimationFactor = Int(floor(sampleRateHz / 40000.0))
        let intermediateSampleRate = sampleRateHz / Double(decimationFactor)
        self.resamplerRatio = AudioManager.audioSampleRate / intermediateSampleRate
    }

    func demodulate(frequencyBand iqSamples: [Float]) -> [Float] {
        guard !firFilter.isEmpty else { return [] }

        // --- STEP 1: Low-Pass Filter (FIR) ---
        let filteredIQ = applyFIR(input: iqSamples, kernel: firFilter)
        
        // --- STEP 2: Decimate ---
        let decimationFactor = Int(floor(2_048_000.0 / 40000.0))
        let decimatedIQ = decimate(input: filteredIQ, factor: decimationFactor)
        
        let sampleCount = decimatedIQ.count / 2
        guard sampleCount > 0 else { return [] }
        
        // --- STEP 3: Squelch ---
        var power: Float = 0.0
        vDSP_rmsqv(decimatedIQ, 1, &power, vDSP_Length(decimatedIQ.count))
        
        guard power > self.squelchLevel else {
            return resample(input: [Float](repeating: 0.0, count: sampleCount))
        }
        
        // --- STEP 4: NFM Demodulation (Polar Discriminator) ---
        var demodulatedAudio = [Float](repeating: 0.0, count: sampleCount)
        for i in 0..<sampleCount {
            let I = decimatedIQ[i * 2]
            let Q = decimatedIQ[i * 2 + 1]
            let real_part = (I * lastI) - (Q * -lastQ)
            let imag_part = (I * -lastQ) + (Q * lastI)
            demodulatedAudio[i] = atan2f(imag_part, real_part)
            lastI = I
            lastQ = Q
        }
        
        // --- STEP 5: Resample to Audio Hardware Rate ---
        return resample(input: demodulatedAudio)
    }
    
    // MARK: - Private DSP Helpers
    
    private func decimate(input: [Float], factor: Int) -> [Float] {
        let outputCount = (input.count / 2) / factor
        guard outputCount > 0 else { return [] }
        var output = [Float](repeating: 0.0, count: outputCount * 2)
        
        // Simple decimation by taking every 'factor' sample
        for i in 0..<outputCount {
            output[i * 2] = input[(i * factor) * 2]
            output[i * 2 + 1] = input[(i * factor) * 2 + 1]
        }
        
        return output
    }

    /// Designs a low-pass FIR filter using the windowed-sinc method.
    private func designLowPassFIR(sampleRate: Double, cutoffFrequency: Double, length: Int) -> [Float] {
        let fc = Float(cutoffFrequency / sampleRate)
        let M = Float(length - 1)
        var kernel = [Float](repeating: 0, count: length)
        
        for i in 0..<length {
            let n = Float(i) - M / 2.0
            // Sinc function
            if n == 0.0 {
                kernel[i] = 2.0 * fc
            } else {
                kernel[i] = sin(2.0 * .pi * fc * n) / (.pi * n)
            }
            // Blackman window
            kernel[i] *= 0.42 - 0.5 * cos(2.0 * .pi * Float(i) / M) + 0.08 * cos(4.0 * .pi * Float(i) / M)
        }
        
        // Normalize the kernel
        let sum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / sum }
        
        return kernel
    }

    /// Applies a FIR filter to a complex I/Q signal.
    private func applyFIR(input: [Float], kernel: [Float]) -> [Float] {
        let inputCount = input.count / 2
        var output = [Float](repeating: 0.0, count: input.count)
        
        // Create separate real and imaginary arrays for processing
        var realInput = [Float](repeating: 0.0, count: inputCount)
        var imagInput = [Float](repeating: 0.0, count: inputCount)
        
        // De-interleave input
        for i in 0..<inputCount {
            realInput[i] = input[i * 2]
            imagInput[i] = input[i * 2 + 1]
        }
        
        var realOutput = [Float](repeating: 0.0, count: inputCount)
        var imagOutput = [Float](repeating: 0.0, count: inputCount)
        
        // Apply convolution for real and imaginary parts separately
        vDSP_conv(realInput, 1, kernel.reversed(), 1, &realOutput, 1, vDSP_Length(inputCount), vDSP_Length(kernel.count))
        vDSP_conv(imagInput, 1, kernel.reversed(), 1, &imagOutput, 1, vDSP_Length(inputCount), vDSP_Length(kernel.count))
        
        // Interleave output
        for i in 0..<inputCount {
            output[i * 2] = realOutput[i]
            output[i * 2 + 1] = imagOutput[i]
        }
        
        return output
    }
    
    /// Resamples audio using simple linear interpolation.
    private func resample(input: [Float]) -> [Float] {
        resamplerInputBuffer.append(contentsOf: input)
        var output = [Float]()
        
        var outputSamplePosition = 0.0
        let inputCount = Double(resamplerInputBuffer.count)
        
        while outputSamplePosition < inputCount - 1 {
            let index = Int(floor(outputSamplePosition))
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
            resamplerInputBuffer.removeAll()
        }
        
        return output
    }
}