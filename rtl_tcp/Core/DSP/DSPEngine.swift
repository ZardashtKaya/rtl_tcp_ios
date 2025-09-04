//
//  Core/DSP/DSPEngine.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Combine
import Foundation
import Accelerate

class DSPEngine: ObservableObject {
    
    // MARK: - Published Properties
    @Published var spectrum: [Float] = []
    @Published var waterfallData: [[Float]] = []
    @Published var dynamicMinDb: Float = -90.0
    @Published var dynamicMaxDb: Float = -10.0
    
    // MARK: - Private Properties
    private var fftSize: Int
    private var fftSetup: FFTSetup
    
    private let dspQueue = DispatchQueue(label: "com.zardashtkaya.rtltcp.dsp", qos: .userInitiated)
    private var isProcessing = false
    private var isUpdatingUI = false
    
    // ----> FIX: Limit buffer growth and add cleanup <----
    private var sampleBuffer = Data()
    private let sampleBufferLock = NSLock()
    private let maxBufferSize = 1024 * 1024 // 1MB limit
    
    private var tuningOffset: Float = 0.5
    private var averagingCount: Int
    private var averagingBuffer: [[Float]] = []
    private var waterfallHeight: Int
    private var autoScaleEnabled: Bool = true
    private let smoothingFactor: Float = 0.05
    
    // ----> FIX: Reuse buffers instead of recreating <----
    private var fftInputReal: [Float]
    private var fftInputImag: [Float]
    private var fftOutputReal: [Float]
    private var fftOutputImag: [Float]
    private var magSquared: [Float]
    private var dbMagnitudes: [Float]
    private var finalMagnitudes: [Float]
    private var floatSamples: [Float]
    private var realSquared: [Float]
    private var imagSquared: [Float]
    private let uint8ToFloatLUT: [Float]
    
    private var demodulator: Demodulator
    var audioManager = AudioManager()
    private var vfoBandwidthHz: Double = 12_500.0
    private var squelchLevel: Float = 0.2
    private var sampleRateHz: Double = 2_048_000.0
    
    // ----> ADD: Performance monitoring <----
    private var lastCleanupTime = Date()
    private var processedChunks = 0
    
    init() {
        self.waterfallHeight = 200
        self.averagingCount = 10
        self.fftSize = 4096
        
        self.demodulator = NFMDemodulator()
        
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        fftSetup = setup
        
        // Pre-compute LUT once
        var lut = [Float](repeating: 0.0, count: 256)
        for i in 0..<256 {
            lut[i] = (Float(i) - 127.5) / 127.5
        }
        self.uint8ToFloatLUT = lut
        
        // Pre-allocate all buffers
        self.spectrum = [Float](repeating: -120.0, count: fftSize)
        self.fftInputReal = [Float](repeating: 0.0, count: fftSize)
        self.fftInputImag = [Float](repeating: 0.0, count: fftSize)
        self.fftOutputReal = [Float](repeating: 0.0, count: fftSize)
        self.fftOutputImag = [Float](repeating: 0.0, count: fftSize)
        self.magSquared = [Float](repeating: 0.0, count: fftSize)
        self.dbMagnitudes = [Float](repeating: 0.0, count: fftSize)
        self.finalMagnitudes = [Float](repeating: 0.0, count: fftSize)
        self.floatSamples = [Float](repeating: 0.0, count: fftSize * 4) // Extra capacity
        self.realSquared = [Float](repeating: 0.0, count: fftSize)
        self.imagSquared = [Float](repeating: 0.0, count: fftSize)
        self.waterfallData = Array(repeating: spectrum, count: waterfallHeight)
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.demodulator.update(bandwidthHz: 12_500.0, sampleRateHz: 2_048_000.0, squelchLevel: 0.2)
        }
    }
    
    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }
    
    // MARK: - Public API
    
    public func setTuningOffset(_ offset: Float) {
        let clampedOffset = max(0.0, min(1.0, offset))
        self.tuningOffset = clampedOffset
    }
    
    public func setAutoScale(isOn: Bool) {
        self.autoScaleEnabled = isOn
    }
    
    public func process(data: Data) {
        guard !data.isEmpty else { return }
        
        sampleBufferLock.lock()
        
        // ----> FIX: Prevent buffer from growing indefinitely <----
        if sampleBuffer.count > maxBufferSize {
            let keepSize = maxBufferSize / 2
            sampleBuffer = sampleBuffer.suffix(keepSize)
            print("⚠️ Buffer overflow, trimmed to \(keepSize) bytes")
        }
        
        sampleBuffer.append(data)
        let bufferSize = sampleBuffer.count
        sampleBufferLock.unlock()
        
        // ----> FIX: Periodic cleanup <----
        if Date().timeIntervalSince(lastCleanupTime) > 10.0 {
            performPeriodicCleanup()
            lastCleanupTime = Date()
        }
        
        // Only process if we're not already processing
        if !isProcessing {
            dspQueue.async { [weak self] in
                self?.runDspLoop()
            }
        }
    }
    
    // ----> ADD: Periodic cleanup <----
    private func performPeriodicCleanup() {
        // Trim averaging buffer if it's too large
        if averagingBuffer.count > averagingCount * 2 {
            averagingBuffer = Array(averagingBuffer.suffix(averagingCount))
        }
        
        // Trim waterfall data if needed
        if waterfallData.count > waterfallHeight * 2 {
            waterfallData = Array(waterfallData.prefix(waterfallHeight))
        }
        
        print("🧹 Performed periodic cleanup - processed \(processedChunks) chunks")
    }
    
    private func runDspLoop() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        
        sampleBufferLock.lock()
        let totalSamples = sampleBuffer.count / 2
        let chunksToProcess = min(totalSamples / fftSize, 4) // Limit chunks per cycle
        
        guard chunksToProcess > 0 else {
            sampleBufferLock.unlock()
            return
        }
        
        let bytesToProcess = chunksToProcess * fftSize * 2
        guard bytesToProcess <= sampleBuffer.count else {
            sampleBufferLock.unlock()
            return
        }
        
        let processingData = sampleBuffer.prefix(bytesToProcess)
        sampleBuffer.removeFirst(bytesToProcess)
        sampleBufferLock.unlock()
        
        // ----> FIX: Reuse buffer instead of growing <----
        let requiredSize = bytesToProcess
        if floatSamples.count < requiredSize {
            floatSamples = [Float](repeating: 0.0, count: requiredSize)
        }
        
        // Convert using LUT
        processingData.withUnsafeBytes { bytes in
            let uint8Ptr = bytes.bindMemory(to: UInt8.self)
            for i in 0..<bytesToProcess {
                floatSamples[i] = uint8ToFloatLUT[Int(uint8Ptr[i])]
            }
        }
        
        // Process chunks with better memory management
        var allAudioSamples = [Float]()
        allAudioSamples.reserveCapacity(chunksToProcess * 1000) // Estimate
        
        for i in 0..<chunksToProcess {
            let start = i * fftSize * 2
            let end = start + fftSize * 2
            guard end <= floatSamples.count else { break }
            
            let chunk = Array(floatSamples[start..<end])
            
            let fftMagnitudes = performFFT(on: chunk)
            guard !fftMagnitudes.isEmpty else { continue }
            
            let frequencyBand = extractFrequencyBand(from: chunk)
            if !frequencyBand.isEmpty {
                let audioSamples = demodulator.demodulate(frequencyBand: frequencyBand)
                if !audioSamples.isEmpty {
                    allAudioSamples.append(contentsOf: audioSamples)
                }
            }
            
            // ----> FIX: Limit averaging buffer size <----
            averagingBuffer.append(fftMagnitudes)
            if averagingBuffer.count > averagingCount {
                averagingBuffer.removeFirst(averagingBuffer.count - averagingCount)
            }
        }
        
        // Send all audio at once to reduce overhead
        if !allAudioSamples.isEmpty {
            audioManager.playSamples(allAudioSamples)
        }
        
        processedChunks += chunksToProcess
        
        // Update UI less frequently
        if !averagingBuffer.isEmpty && processedChunks % 5 == 0 {
            updateUI()
        }
    }
    
    private func updateUI() {
        guard !isUpdatingUI else { return }
        isUpdatingUI = true
        
        guard !averagingBuffer.isEmpty, let firstBuffer = averagingBuffer.first else {
            isUpdatingUI = false
            return
        }
        
        // ----> FIX: Reuse buffer for averaging <----
        if finalMagnitudes.count != firstBuffer.count {
            finalMagnitudes = [Float](repeating: 0.0, count: firstBuffer.count)
        } else {
            // Clear existing data
            vDSP.fill(&finalMagnitudes, with: 0.0)
        }
        
        // Vectorized averaging
        for buffer in averagingBuffer {
            guard buffer.count == finalMagnitudes.count else { continue }
            vDSP.add(finalMagnitudes, buffer, result: &finalMagnitudes)
        }
        let count = Float(averagingBuffer.count)
        vDSP.divide(finalMagnitudes, count, result: &finalMagnitudes)
        
        var newMin = self.dynamicMinDb, newMax = self.dynamicMaxDb
        if self.autoScaleEnabled {
            let currentMin = vDSP.minimum(finalMagnitudes)
            let currentMax = vDSP.maximum(finalMagnitudes)
            newMin = (self.dynamicMinDb * (1.0 - smoothingFactor)) + (currentMin * smoothingFactor)
            newMax = (self.dynamicMaxDb * (1.0 - smoothingFactor)) + (currentMax * smoothingFactor)
        }
        
        // ----> FIX: Copy data instead of referencing <----
        let spectrumCopy = Array(finalMagnitudes)
        
        DispatchQueue.main.async { [weak self] in
            defer { self?.isUpdatingUI = false }
            
            self?.spectrum = spectrumCopy
            if let self = self {
                // ----> FIX: Limit waterfall size <----
                if self.waterfallData.count >= self.waterfallHeight {
                    self.waterfallData.removeLast()
                }
                self.waterfallData.insert(spectrumCopy, at: 0)
            }
            if self?.autoScaleEnabled == true {
                self?.dynamicMinDb = newMin
                self?.dynamicMaxDb = newMax
            }
        }
    }
    
    // Rest of the methods remain the same but with better bounds checking...
    private func performFFT(on samples: [Float]) -> [Float] {
        guard samples.count == fftSize * 2 else {
            return []
        }
        
        samples.withUnsafeBufferPointer { samplesPtr in
            var input = DSPSplitComplex(realp: &fftInputReal, imagp: &fftInputImag)
            var output = DSPSplitComplex(realp: &fftOutputReal, imagp: &fftOutputImag)
            
            let complexPtr = samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize) { $0 }
            vDSP_ctoz(complexPtr, 2, &input, 1, vDSP_Length(fftSize))
            
            let log2n = vDSP_Length(log2(Float(fftSize)))
            vDSP_fft_zop(fftSetup, &input, 1, &output, 1, log2n, FFTDirection(kFFTDirection_Forward))
        }
        
        vDSP.square(fftOutputReal, result: &realSquared)
        vDSP.square(fftOutputImag, result: &imagSquared)
        vDSP.add(realSquared, imagSquared, result: &magSquared)
        
        let epsilon: Float = 1e-10
        vDSP.add(epsilon, magSquared, result: &magSquared)
        vDSP.convert(power: magSquared, toDecibels: &dbMagnitudes, zeroReference: 1.0)
        
        // FFT shift
        let halfSize = fftSize / 2
        for i in 0..<halfSize {
            finalMagnitudes[i] = dbMagnitudes[halfSize + i]
            finalMagnitudes[halfSize + i] = dbMagnitudes[i]
        }
        
        return finalMagnitudes
    }
    
    private func extractFrequencyBand(from iqSamples: [Float]) -> [Float] {
        guard !iqSamples.isEmpty, iqSamples.count % 2 == 0 else {
            return []
        }
        
        let sampleCount = iqSamples.count / 2
        let centerFrequencyRatio = Double(tuningOffset)
        let bandwidthRatio = vfoBandwidthHz / sampleRateHz
        
        let centerSample = Int(centerFrequencyRatio * Double(sampleCount))
        let halfBandwidthSamples = Int(bandwidthRatio * Double(sampleCount) / 2.0)
        
        let startSample = max(0, centerSample - halfBandwidthSamples)
        let endSample = min(sampleCount, centerSample + halfBandwidthSamples)
        
        guard startSample < endSample else {
            return []
        }
        
        var bandSamples = [Float]()
        bandSamples.reserveCapacity((endSample - startSample) * 2)
        
        for i in startSample..<endSample {
            bandSamples.append(iqSamples[i * 2])
            bandSamples.append(iqSamples[i * 2 + 1])
        }
        
        return bandSamples
    }
    
    // Rest of methods remain the same...
    public func updateParameters(fftSize: Int, averagingCount: Int, waterfallHeight: Int) {
        let semaphore = DispatchSemaphore(value: 0)
        
        dspQueue.async {
            self.averagingBuffer.removeAll(keepingCapacity: true)
            self.sampleBufferLock.lock()
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.sampleBufferLock.unlock()
            
            if waterfallHeight != self.waterfallHeight {
                self.waterfallHeight = waterfallHeight
                let emptySpectrum = [Float](repeating: -120.0, count: self.fftSize)
                self.waterfallData = Array(repeating: emptySpectrum, count: self.waterfallHeight)
            }
            
            self.averagingCount = averagingCount
            
            if fftSize != self.fftSize {
                vDSP_destroy_fftsetup(self.fftSetup)
                self.fftSize = fftSize
                
                let log2n = vDSP_Length(log2(Float(self.fftSize)))
                guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                    fatalError("Failed to create FFT setup during parameter update")
                }
                self.fftSetup = setup
                
                // Reallocate buffers
                self.fftInputReal = [Float](repeating: 0.0, count: self.fftSize)
                self.fftInputImag = [Float](repeating: 0.0, count: self.fftSize)
                self.fftOutputReal = [Float](repeating: 0.0, count: self.fftSize)
                self.fftOutputImag = [Float](repeating: 0.0, count: self.fftSize)
                self.magSquared = [Float](repeating: 0.0, count: self.fftSize)
                self.dbMagnitudes = [Float](repeating: 0.0, count: self.fftSize)
                self.finalMagnitudes = [Float](repeating: 0.0, count: self.fftSize)
                self.realSquared = [Float](repeating: 0.0, count: self.fftSize)
                self.imagSquared = [Float](repeating: 0.0, count: self.fftSize)
                self.floatSamples = [Float](repeating: 0.0, count: self.fftSize * 4)
                
                DispatchQueue.main.async {
                    self.spectrum = [Float](repeating: -120.0, count: self.fftSize)
                    self.waterfallData = Array(repeating: self.spectrum, count: self.waterfallHeight)
                }
            }
            
            semaphore.signal()
        }
        
        semaphore.wait()
    }
    
    public func setVFO(bandwidthHz: Double) {
        self.vfoBandwidthHz = bandwidthHz
        updateDemodulatorParameters()
    }
    
    public func setSquelch(level: Float) {
        self.squelchLevel = level
        updateDemodulatorParameters()
    }
    
    public func setSampleRate(_ sampleRate: Double) {
        self.sampleRateHz = sampleRate
        updateDemodulatorParameters()
    }
    
    private func updateDemodulatorParameters() {
        demodulator.update(bandwidthHz: vfoBandwidthHz,
                          sampleRateHz: sampleRateHz,
                          squelchLevel: squelchLevel)
    }
    
    public func testDemodulationChain() {
        print("🧪 Testing demodulation chain...")
        
        let testFreq = 1000.0
        let sampleRate = 2048000.0
        let duration = 0.1
        let sampleCount = Int(duration * sampleRate)
        
        var testIQ = [Float]()
        testIQ.reserveCapacity(sampleCount * 2)
        
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let phase = 2.0 * .pi * testFreq * t
            testIQ.append(Float(cos(phase)))
            testIQ.append(Float(sin(phase)))
        }
        
        print("🧪 Generated \(testIQ.count) test IQ samples")
        
        let audioSamples = demodulator.demodulate(frequencyBand: testIQ)
        print("🧪 Demodulator produced \(audioSamples.count) audio samples")
        
        if !audioSamples.isEmpty {
            audioManager.playSamples(audioSamples)
            print("🧪 Test audio sent to audio manager")
        }
    }
}
