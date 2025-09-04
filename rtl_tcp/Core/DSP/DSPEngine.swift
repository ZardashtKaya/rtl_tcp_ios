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
    
    // ----> FIXED: Use Data for byte buffer, regular arrays for float processing <----
    private var sampleBuffer = Data()
    private let sampleBufferLock = NSLock()
    
    private var tuningOffset: Float = 0.5
    private var averagingCount: Int
    private var averagingBuffer: [[Float]] = []
    private var waterfallHeight: Int
    private var autoScaleEnabled: Bool = true
    private let smoothingFactor: Float = 0.05
    
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
        private var uint8ToFloatLUT: [Float]
        
        private var demodulator: Demodulator
        var audioManager = AudioManager()
        private var vfoBandwidthHz: Double = 12_500.0
        private var squelchLevel: Float = 0.2
        private var sampleRateHz: Double = 2_048_000.0
    
    
    // MARK: - Lifecycle
    init() {
        self.waterfallHeight = 200
        self.averagingCount = 10
        self.fftSize = 4096
        
        // ----> FIX: Initialize demodulator on background queue <----
        self.demodulator = NFMDemodulator()
        
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("Failed to create FFT setup")
        }
        fftSetup = setup
        var lut = [Float](repeating: 0.0, count: 256)
                for i in 0..<256 {
                    lut[i] = (Float(i) - 127.5) / 127.5
                }
        self.uint8ToFloatLUT = lut
        self.spectrum = [Float](repeating: -120.0, count: fftSize)
                self.fftInputReal = [Float](repeating: 0.0, count: fftSize)
                self.fftInputImag = [Float](repeating: 0.0, count: fftSize)
                self.fftOutputReal = [Float](repeating: 0.0, count: fftSize)
                self.fftOutputImag = [Float](repeating: 0.0, count: fftSize)
                self.magSquared = [Float](repeating: 0.0, count: fftSize)
                self.dbMagnitudes = [Float](repeating: 0.0, count: fftSize)
                self.finalMagnitudes = [Float](repeating: 0.0, count: fftSize)
                self.floatSamples = [Float](repeating: 0.0, count: fftSize * 2)
                self.realSquared = [Float](repeating: 0.0, count: fftSize)
                self.imagSquared = [Float](repeating: 0.0, count: fftSize)
                self.waterfallData = Array(repeating: spectrum, count: waterfallHeight)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.demodulator.update(bandwidthHz: 12_500.0, sampleRateHz: 2_048_000.0, squelchLevel: 0.2)
        }
            }
            
            deinit { vDSP_destroy_fftsetup(fftSetup) }
            
            // MARK: - Public API
            
            public func setTuningOffset(_ offset: Float) {
                let clampedOffset = max(0.0, min(1.0, offset))
                self.tuningOffset = clampedOffset
            }
            
            public func setAutoScale(isOn: Bool) { self.autoScaleEnabled = isOn }
            
    public func process(data: Data) {
        guard !data.isEmpty else { return }
        
        // ----> ADD: Debug data reception <----
         var totalBytesReceived = 0
         var dataPacketsReceived = 0
        totalBytesReceived += data.count
        dataPacketsReceived += 1
        
        if dataPacketsReceived % 100 == 0 {
            print("📡 Received \(dataPacketsReceived) packets, \(totalBytesReceived) total bytes, last packet: \(data.count) bytes")
            
            // Sample the first few bytes to see what we're getting
            let sampleBytes = data.prefix(8)
            let byteValues = sampleBytes.map { String($0) }.joined(separator: ", ")
            print("📡 Sample bytes: [\(byteValues)]")
        }
        
        sampleBufferLock.lock()
        sampleBuffer.append(data)
        sampleBufferLock.unlock()
        
        dspQueue.async { self.runDspLoop() }
    }
            
            // MARK: - Core DSP Logic
    public func testDemodulationChain() {
        print("🧪 Testing demodulation chain...")
        
        // Generate test IQ data (a simple tone)
        let testFreq = 1000.0 // 1kHz tone
        let sampleRate = 2048000.0
        let duration = 0.1 // 100ms
        let sampleCount = Int(duration * sampleRate)
        
        var testIQ = [Float]()
        for i in 0..<sampleCount {
            let t = Double(i) / sampleRate
            let phase = 2.0 * .pi * testFreq * t
            testIQ.append(Float(cos(phase))) // I
            testIQ.append(Float(sin(phase))) // Q
        }
        
        print("🧪 Generated \(testIQ.count) test IQ samples")
        
        let audioSamples = demodulator.demodulate(frequencyBand: testIQ)
        print("🧪 Demodulator produced \(audioSamples.count) audio samples")
        
        if !audioSamples.isEmpty {
            audioManager.playSamples(audioSamples)
            print("🧪 Test audio sent to audio manager")
        }
    }
    
    
    private func runDspLoop() {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }
        
        sampleBufferLock.lock()
        let totalSamples = sampleBuffer.count / 2
        let chunksToProcess = totalSamples / fftSize
        
        guard chunksToProcess > 0 else {
            sampleBufferLock.unlock()
            return
        }
        
        let bytesToProcess = chunksToProcess * fftSize * 2
        guard bytesToProcess <= sampleBuffer.count else {
            print("⚠️ Buffer underrun: requested \(bytesToProcess), available \(sampleBuffer.count)")
            sampleBufferLock.unlock()
            return
        }
        
        let processingData = sampleBuffer.prefix(bytesToProcess)
        sampleBuffer.removeFirst(bytesToProcess)
        sampleBufferLock.unlock()
        
        // ----> ADD: Debug data reception <----
        var dataChunksProcessed = 0
        dataChunksProcessed += 1
        if dataChunksProcessed % 100 == 0 {
            print("📡 DSP processed \(dataChunksProcessed) data chunks, current size: \(bytesToProcess) bytes")
        }
        
        if floatSamples.count < bytesToProcess {
            floatSamples = [Float](repeating: 0.0, count: bytesToProcess)
        }
        
        // Vectorized uint8 to float conversion using LUT
        processingData.withUnsafeBytes { bytes in
            let uint8Ptr = bytes.bindMemory(to: UInt8.self)
            for i in 0..<bytesToProcess {
                floatSamples[i] = uint8ToFloatLUT[Int(uint8Ptr[i])]
            }
        }
        
        // Process each chunk
        var processedAnyChunk = false
        var totalAudioSamples = 0
        
        for i in 0..<chunksToProcess {
            let start = i * fftSize * 2
            let end = start + fftSize * 2
            guard end <= floatSamples.count else {
                print("⚠️ Chunk bounds error: start=\(start), end=\(end), buffer size=\(floatSamples.count)")
                break
            }
            let chunk = Array(floatSamples[start..<end])
            
            let fftMagnitudes = performFFT(on: chunk)
            guard !fftMagnitudes.isEmpty else { continue }
            
            // ----> ADD: Debug frequency band extraction <----
            let frequencyBand = extractFrequencyBand(from: chunk) // Use IQ data, not FFT magnitudes!
            if frequencyBand.isEmpty {
                print("⚠️ Empty frequency band extracted")
                continue
            }
            
            let audioSamples = demodulator.demodulate(frequencyBand: frequencyBand)
            
            // ----> ADD: Debug audio output <----
            if !audioSamples.isEmpty {
                totalAudioSamples += audioSamples.count
                audioManager.playSamples(audioSamples)
            } else {
                print("⚠️ Demodulator returned empty audio samples")
            }
            
            averagingBuffer.append(fftMagnitudes)
            if averagingBuffer.count > averagingCount {
                averagingBuffer.removeFirst()
            }
            processedAnyChunk = true
        }
        
        // ----> ADD: Debug audio production <----
        if totalAudioSamples > 0 && dataChunksProcessed % 50 == 0 {
            print("🎵 Produced \(totalAudioSamples) audio samples from \(chunksToProcess) chunks")
        }
        
        // Update UI only if we processed data
        if processedAnyChunk && !averagingBuffer.isEmpty {
            updateUI()
        }
            }
            
    private func updateUI() {
            // Limit UI update frequency
            guard !isUpdatingUI else { return }
            isUpdatingUI = true
            
            // ----> FIX: Add safety check for averaging buffer <----
            guard !averagingBuffer.isEmpty, let firstBuffer = averagingBuffer.first else {
                isUpdatingUI = false
                return
            }
            
            var averagedMagnitudes = [Float](repeating: 0.0, count: firstBuffer.count)
            
            // Vectorized averaging with bounds checking
            for buffer in averagingBuffer {
                guard buffer.count == averagedMagnitudes.count else {
                    print("⚠️ Buffer size mismatch in averaging: expected \(averagedMagnitudes.count), got \(buffer.count)")
                    continue
                }
                vDSP.add(averagedMagnitudes, buffer, result: &averagedMagnitudes)
            }
            let count = Float(averagingBuffer.count)
            vDSP.divide(averagedMagnitudes, count, result: &averagedMagnitudes)
            
            var newMin = self.dynamicMinDb, newMax = self.dynamicMaxDb
            if self.autoScaleEnabled {
                let currentMin = vDSP.minimum(averagedMagnitudes)
                let currentMax = vDSP.maximum(averagedMagnitudes)
                newMin = (self.dynamicMinDb * (1.0 - smoothingFactor)) + (currentMin * smoothingFactor)
                newMax = (self.dynamicMaxDb * (1.0 - smoothingFactor)) + (currentMax * smoothingFactor)
            }
            
            // Throttle UI updates
            DispatchQueue.main.async { [weak self] in
                defer { self?.isUpdatingUI = false }
                
                self?.spectrum = averagedMagnitudes
                if let self = self, !self.waterfallData.isEmpty {
                    self.waterfallData.removeLast()
                    self.waterfallData.insert(averagedMagnitudes, at: 0)
                }
                if self?.autoScaleEnabled == true {
                    self?.dynamicMinDb = newMin
                    self?.dynamicMaxDb = newMax
                }
            }
        }
            
    private func performFFT(on samples: [Float]) -> [Float] {
            // ----> FIX: Add comprehensive bounds checking <----
            guard samples.count == fftSize * 2 else {
                print("⚠️ FFT input size mismatch: expected \(fftSize * 2), got \(samples.count)")
                return []
            }
            
            // Use vDSP_ctoz for efficient deinterleaving
            samples.withUnsafeBufferPointer { samplesPtr in
                fftInputReal.withUnsafeMutableBufferPointer { realPtr in
                    fftInputImag.withUnsafeMutableBufferPointer { imagPtr in
                        fftOutputReal.withUnsafeMutableBufferPointer { outRealPtr in
                            fftOutputImag.withUnsafeMutableBufferPointer { outImagPtr in
                                
                                var input = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                                var output = DSPSplitComplex(realp: outRealPtr.baseAddress!, imagp: outImagPtr.baseAddress!)
                                
                                let complexPtr = samplesPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize) { $0 }
                                vDSP_ctoz(complexPtr, 2, &input, 1, vDSP_Length(fftSize))
                                
                                let log2n = vDSP_Length(log2(Float(fftSize)))
                                vDSP_fft_zop(fftSetup, &input, 1, &output, 1, log2n, FFTDirection(kFFTDirection_Forward))
                            }
                        }
                    }
                }
            }
        
        vDSP.square(fftOutputReal, result: &realSquared)
        vDSP.square(fftOutputImag, result: &imagSquared)
        vDSP.add(realSquared, imagSquared, result: &magSquared)
        
        let epsilon: Float = 1e-10
        vDSP.add(epsilon, magSquared, result: &magSquared)
        vDSP.convert(power: magSquared, toDecibels: &dbMagnitudes, zeroReference: 1.0)
        
        // FFT shift with bounds checking
        let halfSize = fftSize / 2
        guard halfSize > 0 && halfSize < fftSize else {
            print("⚠️ Invalid FFT size for shift: \(fftSize)")
            return Array(dbMagnitudes)
        }
        
        finalMagnitudes.replaceSubrange(0..<halfSize, with: dbMagnitudes[halfSize..<fftSize])
        finalMagnitudes.replaceSubrange(halfSize..<fftSize, with: dbMagnitudes[0..<halfSize])
        
        return finalMagnitudes
    }
    
    private func extractFrequencyBand(from iqSamples: [Float]) -> [Float] {
        guard !iqSamples.isEmpty, iqSamples.count % 2 == 0 else {
            print("⚠️ Invalid IQ samples for frequency extraction")
            return []
        }
        
        let sampleCount = iqSamples.count / 2
        let centerFrequencyRatio = Double(tuningOffset)
        let bandwidthRatio = vfoBandwidthHz / sampleRateHz
        
        // Calculate which samples to extract based on frequency
        let centerSample = Int(centerFrequencyRatio * Double(sampleCount))
        let halfBandwidthSamples = Int(bandwidthRatio * Double(sampleCount) / 2.0)
        
        let startSample = max(0, centerSample - halfBandwidthSamples)
        let endSample = min(sampleCount, centerSample + halfBandwidthSamples)
        
        guard startSample < endSample else {
            print("⚠️ Invalid frequency band: start=\(startSample), end=\(endSample)")
            return []
        }
        
        // Extract IQ samples for the frequency band
        var bandSamples = [Float]()
        bandSamples.reserveCapacity((endSample - startSample) * 2)
        
        for i in startSample..<endSample {
            bandSamples.append(iqSamples[i * 2])     // I
            bandSamples.append(iqSamples[i * 2 + 1]) // Q
        }
        
        return bandSamples
    }
    
            
            public func updateParameters(fftSize: Int, averagingCount: Int, waterfallHeight: Int) {
                let semaphore = DispatchSemaphore(value: 0)
                
                dspQueue.async {
                    self.averagingBuffer.removeAll()
                    self.sampleBufferLock.lock()
                    self.sampleBuffer.removeAll()
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
                        self.floatSamples = [Float](repeating: 0.0, count: self.fftSize * 2)
                        
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
        }
