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
    private var fftSetup: FFTSetup?
    
    private let dspQueue = DispatchQueue(label: "com.zardashtkaya.rtltcp.dsp", qos: .userInitiated)
    private var isProcessing = false
    private var isUpdatingUI = false
    
    private var sampleBuffer = Data()
    private let sampleBufferLock = NSLock()
    private let maxBufferSize = 256 * 1024 // Reduce from 1MB to 256KB
    
    private var tuningOffset: Float = 0.5
    private var averagingCount: Int
    private var averagingBuffer: [[Float]] = []
    private var waterfallHeight: Int
    private var autoScaleEnabled: Bool = true
    private let smoothingFactor: Float = 0.05
    
    // ----> FIX: Make buffers optional and manage them properly <----
    private var fftInputReal: [Float] = []
    private var fftInputImag: [Float] = []
    private var fftOutputReal: [Float] = []
    private var fftOutputImag: [Float] = []
    private var magSquared: [Float] = []
    private var dbMagnitudes: [Float] = []
    private var finalMagnitudes: [Float] = []
    private var floatSamples: [Float] = []
    private var realSquared: [Float] = []
    private var imagSquared: [Float] = []
    private let uint8ToFloatLUT: [Float]
    
    var demodulator: Demodulator
    var audioManager = AudioManager()
    private var vfoBandwidthHz: Double = 12_500.0
    private var squelchLevel: Float = 0.2
    private var sampleRateHz: Double = 2_048_000.0
    
    private var lastCleanupTime = Date()
    private var processedChunks = 0
    
    private var lastUIUpdateTime = Date()
    private let minUIUpdateInterval: TimeInterval = 1.0 / 30.0
    private var pendingUIUpdate = false
    
    // ----> ADD: Initialization flag <----
    private var isInitialized = false
    private var fftErrorCount = 0
    private let maxFFTErrors = 10

    private func performFFTSafely(on samples: [Float]) -> [Float] {
        if fftErrorCount >= maxFFTErrors {
            // Return empty array if too many errors
            return []
        }
        
        do {
            let result = performFFT(on: samples)
            if !result.isEmpty {
                fftErrorCount = 0 // Reset error count on success
            }
            return result
        } catch {
            fftErrorCount += 1
            print("⚠️ FFT error \(fftErrorCount)/\(maxFFTErrors): \(error)")
            return []
        }
    }
    

    init() {
        print("🔧 DSPEngine init starting...")
            self.waterfallHeight = 200
            self.averagingCount = 10
            self.fftSize = 4096
            
            self.demodulator = NFMDemodulator()
            
            // Pre-compute LUT once
            var lut = [Float](repeating: 0.0, count: 256)
            for i in 0..<256 {
                lut[i] = (Float(i) - 127.5) / 127.5
            }
            self.uint8ToFloatLUT = lut
            
            print("🔧 Initializing buffers...")
            initializeBuffers()
            
            print("🔧 Setting up FFT...")
            setupFFT()
            
            self.isInitialized = true
            print("🔧 DSPEngine init complete")
            
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.demodulator.update(bandwidthHz: 12_500.0, sampleRateHz: 2_048_000.0, squelchLevel: 0.2)
            }
    }
    
    // ----> ADD: Safe buffer initialization <----
    private func initializeBuffers() {
        print("🔧 Clearing existing buffers...")
        
        // Clear existing buffers first
        spectrum.removeAll(keepingCapacity: false)
        fftInputReal.removeAll(keepingCapacity: false)
        fftInputImag.removeAll(keepingCapacity: false)
        fftOutputReal.removeAll(keepingCapacity: false)
        fftOutputImag.removeAll(keepingCapacity: false)
        magSquared.removeAll(keepingCapacity: false)
        dbMagnitudes.removeAll(keepingCapacity: false)
        finalMagnitudes.removeAll(keepingCapacity: false)
        floatSamples.removeAll(keepingCapacity: false)
        realSquared.removeAll(keepingCapacity: false)
        imagSquared.removeAll(keepingCapacity: false)
        
        print("🔧 Allocating new buffers for FFT size \(fftSize)...")
        
        // Initialize with proper sizes - use explicit allocation
        self.spectrum = Array(repeating: -120.0, count: fftSize)
        self.fftInputReal = Array(repeating: 0.0, count: fftSize)
        self.fftInputImag = Array(repeating: 0.0, count: fftSize)
        self.fftOutputReal = Array(repeating: 0.0, count: fftSize)
        self.fftOutputImag = Array(repeating: 0.0, count: fftSize)
        self.magSquared = Array(repeating: 0.0, count: fftSize)
        self.dbMagnitudes = Array(repeating: 0.0, count: fftSize)
        self.finalMagnitudes = Array(repeating: 0.0, count: fftSize)
        self.floatSamples = Array(repeating: 0.0, count: fftSize * 4)
        self.realSquared = Array(repeating: 0.0, count: fftSize)
        self.imagSquared = Array(repeating: 0.0, count: fftSize)
        self.waterfallData = Array(repeating: spectrum, count: waterfallHeight)
        
        // Verify allocation
        let totalMemory = (fftSize * 11 + fftSize * 4) * MemoryLayout<Float>.size + waterfallHeight * fftSize * MemoryLayout<Float>.size
        print("✅ Buffers initialized - Total memory: \(totalMemory / 1024)KB")
        
        // Verify all buffer sizes
        print("🔧 Buffer sizes: spectrum=\(spectrum.count), fftInputReal=\(fftInputReal.count), fftInputImag=\(fftInputImag.count)")
        print("🔧 Output sizes: fftOutputReal=\(fftOutputReal.count), fftOutputImag=\(fftOutputImag.count)")
    }
    
    // ----> ADD: Safe FFT setup <----
    private func setupFFT() {
        // Clean up existing setup first
        cleanupFFT()
        
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard log2n > 0 && log2n < 20 else { // Sanity check
            print("❌ Invalid FFT size: \(fftSize), log2n: \(log2n)")
            return
        }
        
        // ----> SAFER: Try multiple times if needed <----
        var attempts = 0
        while attempts < 3 && fftSetup == nil {
            if let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) {
                fftSetup = setup
                print("✅ FFT setup created for size \(fftSize) on attempt \(attempts + 1)")
                break
            } else {
                attempts += 1
                print("⚠️ FFT setup attempt \(attempts) failed for size \(fftSize)")
                Thread.sleep(forTimeInterval: 0.01) // Brief pause
            }
        }
        
        if fftSetup == nil {
            print("❌ Failed to create FFT setup after \(attempts) attempts")
        }
    }

    private func cleanupFFT() {
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
            fftSetup = nil
            print("🗑️ FFT setup destroyed")
        }
    }

    deinit {
        print("🗑️ DSPEngine deinit")
        // Make sure we're on the main thread for cleanup
        if Thread.isMainThread {
            cleanupFFT()
        } else {
            DispatchQueue.main.sync {
                cleanupFFT()
            }
        }
    }

    
    
    
    public func setTuningOffset(_ offset: Float) {
        let clampedOffset = max(0.0, min(1.0, offset))
        self.tuningOffset = clampedOffset
    }
    
    public func setAutoScale(isOn: Bool) {
        self.autoScaleEnabled = isOn
    }
    
    public func process(data: Data) {
        guard !data.isEmpty, isInitialized else { return }
        
        sampleBufferLock.lock()
        
        if sampleBuffer.count > maxBufferSize {
            let keepSize = maxBufferSize / 2
            sampleBuffer = sampleBuffer.suffix(keepSize)
            print("⚠️ Buffer overflow, trimmed to \(keepSize) bytes")
        }
        
        sampleBuffer.append(data)
        sampleBufferLock.unlock()
        
        if Date().timeIntervalSince(lastCleanupTime) > 10.0 {
            performPeriodicCleanup()
            lastCleanupTime = Date()
        }
        
        // ----> FIX: Only process if not already processing <----
        if !isProcessing {
            dspQueue.async { [weak self] in
                self?.runDspLoop()
            }
        }
    }
    
    private func performPeriodicCleanup() {
        // ----> FIX: More aggressive cleanup <----
        sampleBufferLock.lock()
        if sampleBuffer.count > maxBufferSize {
            let keepSize = maxBufferSize / 4 // Keep only 25%
            sampleBuffer = sampleBuffer.suffix(keepSize)
            print("🧹 Aggressive buffer trim to \(keepSize) bytes")
        }
        sampleBufferLock.unlock()
        
        if averagingBuffer.count > averagingCount {
            averagingBuffer = Array(averagingBuffer.suffix(averagingCount))
        }
        
        if waterfallData.count > waterfallHeight {
            waterfallData = Array(waterfallData.prefix(waterfallHeight))
        }
        
        print("🧹 Cleanup complete - processed \(processedChunks) chunks")
    }
    
    
    
    private func runDspLoop() {
        guard !isProcessing, isInitialized, fftSetup != nil else { return }
        isProcessing = true
        defer { isProcessing = false }
        
        sampleBufferLock.lock()
        let totalSamples = sampleBuffer.count / 2
        
        // ----> FIX: Process smaller chunks more efficiently <----
        let maxChunksPerRun = 1 // Process only 1 chunk at a time
        let chunksToProcess = min(totalSamples / fftSize, maxChunksPerRun)
        
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
        
        // ----> FIX: Ensure buffer is large enough <----
        let requiredSize = bytesToProcess
        if floatSamples.count < requiredSize {
            floatSamples = [Float](repeating: 0.0, count: requiredSize)
        }
        
        // Convert using LUT - this is fast
        processingData.withUnsafeBytes { bytes in
            let uint8Ptr = bytes.bindMemory(to: UInt8.self)
            for i in 0..<bytesToProcess {
                floatSamples[i] = uint8ToFloatLUT[Int(uint8Ptr[i])]
            }
        }
        
        // ----> FIX: Prioritize audio over spectrum <----
        var allAudioSamples = [Float]()
        allAudioSamples.reserveCapacity(chunksToProcess * 2000) // Larger capacity
        
        var latestFFTMagnitudes: [Float]?
        
        for i in 0..<chunksToProcess {
            let start = i * fftSize * 2
            let end = start + fftSize * 2
            guard end <= floatSamples.count else { break }
            
            let chunk = Array(floatSamples[start..<end])
            
            // ----> FIX: Do FFT less frequently <----
            if processedChunks % 4 == 0 { // Only do FFT every 4th chunk
                
                let fftMagnitudes = performFFTSafely(on: chunk)
                if !fftMagnitudes.isEmpty {
                    latestFFTMagnitudes = fftMagnitudes
                }
            }
            
            // ----> PRIORITY: Always process audio <----
            let frequencyBand = extractFrequencyBand(from: chunk)
            if !frequencyBand.isEmpty {
                let audioSamples = demodulator.demodulate(frequencyBand: frequencyBand)
                if !audioSamples.isEmpty {
                    allAudioSamples.append(contentsOf: audioSamples)
                }
            }
        }
        
        // ----> FIX: Send audio immediately <----
        if !allAudioSamples.isEmpty {
            audioManager.playSamples(allAudioSamples)
        }
        
        // ----> FIX: Update spectrum less frequently <----
        if let fftData = latestFFTMagnitudes {
            averagingBuffer.append(fftData)
            if averagingBuffer.count > averagingCount {
                averagingBuffer.removeFirst(averagingBuffer.count - averagingCount)
            }
            scheduleUIUpdate()
        }
        
        processedChunks += chunksToProcess
        
        // ----> FIX: Schedule next processing immediately if there's more data <----
        sampleBufferLock.lock()
        let hasMoreData = sampleBuffer.count >= fftSize * 2
        sampleBufferLock.unlock()
        
        if hasMoreData {
            dspQueue.async { [weak self] in
                self?.runDspLoop()
            }
        }
    }
    
    private func scheduleUIUpdate() {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastUIUpdateTime)
        
        if timeSinceLastUpdate >= minUIUpdateInterval && !pendingUIUpdate {
            pendingUIUpdate = true
            lastUIUpdateTime = now
            
            DispatchQueue.main.async { [weak self] in
                self?.updateUI()
            }
        } else if !pendingUIUpdate {
            pendingUIUpdate = true
            let delay = minUIUpdateInterval - timeSinceLastUpdate
            
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.updateUI()
            }
        }
    }
    
    private func updateUI() {
        defer { pendingUIUpdate = false }
        
        guard !averagingBuffer.isEmpty, let firstBuffer = averagingBuffer.first else {
            return
        }
        
        // ----> FIX: Ensure buffer size matches <----
        if finalMagnitudes.count != firstBuffer.count {
            finalMagnitudes = [Float](repeating: 0.0, count: firstBuffer.count)
        } else {
            // Clear existing data safely
            for i in 0..<finalMagnitudes.count {
                finalMagnitudes[i] = 0.0
            }
        }
        
        // Vectorized averaging with bounds checking
        for buffer in averagingBuffer {
            guard buffer.count == finalMagnitudes.count else {
                print("⚠️ Buffer size mismatch in averaging: expected \(finalMagnitudes.count), got \(buffer.count)")
                continue
            }
            vDSP.add(finalMagnitudes, buffer, result: &finalMagnitudes)
        }
        let count = Float(averagingBuffer.count)
        if count > 0 {
            vDSP.divide(finalMagnitudes, count, result: &finalMagnitudes)
        }
        
        var newMin = self.dynamicMinDb, newMax = self.dynamicMaxDb
        if self.autoScaleEnabled && !finalMagnitudes.isEmpty {
            let currentMin = vDSP.minimum(finalMagnitudes)
            let currentMax = vDSP.maximum(finalMagnitudes)
            newMin = (self.dynamicMinDb * (1.0 - smoothingFactor)) + (currentMin * smoothingFactor)
            newMax = (self.dynamicMaxDb * (1.0 - smoothingFactor)) + (currentMax * smoothingFactor)
        }
        
        let spectrumCopy = Array(finalMagnitudes)
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.spectrum = spectrumCopy
            
            if self.waterfallData.count >= self.waterfallHeight {
                self.waterfallData.removeLast()
            }
            self.waterfallData.insert(spectrumCopy, at: 0)
            
            if self.autoScaleEnabled {
                self.dynamicMinDb = newMin
                self.dynamicMaxDb = newMax
            }
        }
    }
    
    // ----> FIX: Add safety checks to FFT <----
    private func performFFT(on samples: [Float]) -> [Float] {
        guard samples.count == fftSize * 2,
              let setup = fftSetup else {
            print("⚠️ FFT precondition failed: samples=\(samples.count), fftSize=\(fftSize), setup=\(fftSetup != nil)")
            return []
        }
        
        // Ensure all buffers are the correct size
        guard fftInputReal.count == fftSize,
              fftInputImag.count == fftSize,
              fftOutputReal.count == fftSize,
              fftOutputImag.count == fftSize,
              magSquared.count == fftSize,
              dbMagnitudes.count == fftSize,
              finalMagnitudes.count == fftSize else {
            print("⚠️ Buffer size mismatch in FFT")
            return []
        }
        
        // Deinterleave samples safely
        for i in 0..<fftSize {
            let realIndex = i * 2
            let imagIndex = i * 2 + 1
            
            if realIndex < samples.count && imagIndex < samples.count {
                fftInputReal[i] = samples[realIndex]
                fftInputImag[i] = samples[imagIndex]
            } else {
                fftInputReal[i] = 0.0
                fftInputImag[i] = 0.0
            }
        }
        
        // ----> SAFER FFT APPROACH: Use vDSP_fft_zrip instead <----
        let log2n = vDSP_Length(log2(Float(fftSize)))
        
        // Create temporary arrays for the FFT operation
        var tempReal = fftInputReal
        var tempImag = fftInputImag
        var outputReal = Array(repeating: Float(0.0), count: fftSize)
        var outputImag = Array(repeating: Float(0.0), count: fftSize)
        
        tempReal.withUnsafeMutableBufferPointer { realPtr in
            tempImag.withUnsafeMutableBufferPointer { imagPtr in
                outputReal.withUnsafeMutableBufferPointer { outRealPtr in
                    outputImag.withUnsafeMutableBufferPointer { outImagPtr in
                        
                        guard let realBase = realPtr.baseAddress,
                              let imagBase = imagPtr.baseAddress,
                              let outRealBase = outRealPtr.baseAddress,
                              let outImagBase = outImagPtr.baseAddress else {
                            print("⚠️ FFT buffer pointer error")
                            return
                        }
                        
                        var input = DSPSplitComplex(realp: realBase, imagp: imagBase)
                        var output = DSPSplitComplex(realp: outRealBase, imagp: outImagBase)
                        
                        // Use the safer FFT function
                        vDSP_fft_zop(setup, &input, 1, &output, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }
        }
        
        // Copy results back safely
        for i in 0..<fftSize {
            if i < outputReal.count && i < outputImag.count {
                fftOutputReal[i] = outputReal[i]
                fftOutputImag[i] = outputImag[i]
            }
        }
        
        // Calculate magnitudes using temporary arrays
        var tempRealSquared = Array(repeating: Float(0.0), count: fftSize)
        var tempImagSquared = Array(repeating: Float(0.0), count: fftSize)
        var tempMagSquared = Array(repeating: Float(0.0), count: fftSize)
        var tempDbMagnitudes = Array(repeating: Float(0.0), count: fftSize)
        
        vDSP.square(fftOutputReal, result: &tempRealSquared)
        vDSP.square(fftOutputImag, result: &tempImagSquared)
        vDSP.add(tempRealSquared, tempImagSquared, result: &tempMagSquared)
        
        let epsilon: Float = 1e-10
        vDSP.add(epsilon, tempMagSquared, result: &tempMagSquared)
        vDSP.convert(power: tempMagSquared, toDecibels: &tempDbMagnitudes, zeroReference: 1.0)
        
        // FFT shift with bounds checking
        let halfSize = fftSize / 2
        guard halfSize > 0 && halfSize < fftSize else {
            print("⚠️ FFT shift bounds error")
            return []
        }
        
        // Create result array
        var result = Array(repeating: Float(0.0), count: fftSize)
        
        for i in 0..<halfSize {
            if halfSize + i < tempDbMagnitudes.count && i < result.count && halfSize + i < result.count {
                result[i] = tempDbMagnitudes[halfSize + i]
                result[halfSize + i] = tempDbMagnitudes[i]
            }
        }
        
        return result
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
    
    // ----> FIX: Make parameter updates safer <----
    public func updateParameters(fftSize: Int, averagingCount: Int, waterfallHeight: Int) {
        print("🔄 Updating parameters: FFT=\(fftSize), Avg=\(averagingCount), Height=\(waterfallHeight)")
        
        let semaphore = DispatchSemaphore(value: 0)
        
        dspQueue.async { [weak self] in
            guard let self = self else {
                semaphore.signal()
                return
            }
            
            // Wait for any current processing to finish
            var waitCount = 0
            while self.isProcessing && waitCount < 100 {
                Thread.sleep(forTimeInterval: 0.01)
                waitCount += 1
            }
            
            if waitCount >= 100 {
                print("⚠️ Timeout waiting for processing to stop")
            }
            
            // Clear buffers
            self.averagingBuffer.removeAll(keepingCapacity: false)
            self.sampleBufferLock.lock()
            self.sampleBuffer.removeAll(keepingCapacity: false)
            self.sampleBufferLock.unlock()
            
            // Update simple parameters first
            if waterfallHeight != self.waterfallHeight {
                self.waterfallHeight = waterfallHeight
            }
            
            self.averagingCount = averagingCount
            
            // Handle FFT size change carefully
            if fftSize != self.fftSize {
                print("🔄 Changing FFT size from \(self.fftSize) to \(fftSize)")
                
                // Clean up old FFT setup safely
                self.cleanupFFT()
                
                // Update size
                self.fftSize = fftSize
                
                // Reinitialize everything
                self.initializeBuffers()
                self.setupFFT()
                
                // Update UI on main thread
                DispatchQueue.main.async {
                    self.spectrum = Array(repeating: -120.0, count: self.fftSize)
                    self.waterfallData = Array(repeating: self.spectrum, count: self.waterfallHeight)
                    print("✅ UI updated for new FFT size")
                }
            }
            
            semaphore.signal()
        }
        
        // Wait with timeout
        let result = semaphore.wait(timeout: .now() + 5.0)
        if result == .timedOut {
            print("⚠️ Parameter update timed out")
        } else {
            print("✅ Parameters updated successfully")
        }
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
    public func resetForConnection() {
        print("🔧 Resetting DSP engine for new connection...")
        
        dspQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Wait for any current processing to finish
            while self.isProcessing {
                Thread.sleep(forTimeInterval: 0.01)
            }
            
            // Clear all buffers
            self.sampleBufferLock.lock()
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.sampleBufferLock.unlock()
            
            self.averagingBuffer.removeAll(keepingCapacity: true)
            
            // Reset counters
            self.processedChunks = 0
            self.lastCleanupTime = Date()
            self.lastUIUpdateTime = Date()
            self.pendingUIUpdate = false
            
            // Reset audio manager
            self.audioManager.resetForConnection()
            
            // Reset demodulator
            self.demodulator.update(
                bandwidthHz: self.vfoBandwidthHz,
                sampleRateHz: self.sampleRateHz,
                squelchLevel: self.squelchLevel
            )
            
            // Reset UI data
            DispatchQueue.main.async {
                self.spectrum = [Float](repeating: -120.0, count: self.fftSize)
                self.waterfallData = Array(repeating: self.spectrum, count: self.waterfallHeight)
                self.dynamicMinDb = -90.0
                self.dynamicMaxDb = -10.0
            }
            
            print("🔧 DSP engine reset complete")
        }
    }

    public func stopForDisconnection() {
        print("🔧 Stopping DSP engine for disconnection...")
        
        dspQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Wait for any current processing to finish
            while self.isProcessing {
                Thread.sleep(forTimeInterval: 0.01)
            }
            
            // Clear all buffers
            self.sampleBufferLock.lock()
            self.sampleBuffer.removeAll(keepingCapacity: true)
            self.sampleBufferLock.unlock()
            
            self.averagingBuffer.removeAll(keepingCapacity: true)
            
            // Stop audio
            self.audioManager.stopForDisconnection()
            
            print("🔧 DSP engine stopped")
        }
    }
}
