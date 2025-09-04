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
    private var pendingData = Data()
    private let pendingDataLock = NSLock()
    
    private var tuningOffset: Float = 0.5
    private var averagingCount: Int
    private var averagingBuffer: [[Float]] = []
    private var waterfallHeight: Int
    private var autoScaleEnabled: Bool = true
    private let smoothingFactor: Float = 0.05
    
    // --- Reusable Buffers ---
    private var fftInputReal: [Float]
    private var fftInputImag: [Float]
    private var fftOutputReal: [Float]
    private var fftOutputImag: [Float]
    private var magSquared: [Float]
    private var dbMagnitudes: [Float]
    private var finalMagnitudes: [Float]
    private var realSquared: [Float]
    private var imagSquared: [Float]
    private var floatSamples: [Float]
       private var phaseRamp: [Float]
       private var phasorReal, phasorImag, chunkReal, chunkImag, shiftedReal, shiftedImag: [Float]
    private var demodulator: Demodulator
    private let audioManager = AudioManager()
    private var vfoBandwidthHz: Double = 12_500.0
    private var squelchLevel: Float = 0.2
    private var sampleRateHz: Double = 2_048_000.0

    private var vfoPhase: Float = 0.0
    private var vfoPhaseIncrement: Float = 0.0

    private var sampleBuffer = Data()

    
    // MARK: - Lifecycle
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
        
        spectrum = [Float](repeating: -120.0, count: fftSize)

        phaseRamp = [Float](repeating: 0.0, count: fftSize)
        realSquared = [Float](repeating: 0.0, count: fftSize)
        imagSquared = [Float](repeating: 0.0, count: fftSize)
        phasorReal = [Float](repeating: 0.0, count: fftSize)
        phasorImag = [Float](repeating: 0.0, count: fftSize)
        chunkReal = [Float](repeating: 0.0, count: fftSize)
        chunkImag = [Float](repeating: 0.0, count: fftSize)
        shiftedReal = [Float](repeating: 0.0, count: fftSize)
        shiftedImag = [Float](repeating: 0.0, count: fftSize)
        fftInputReal = [Float](repeating: 0.0, count: fftSize)
        fftInputImag = [Float](repeating: 0.0, count: fftSize)
        fftOutputReal = [Float](repeating: 0.0, count: fftSize)
        fftOutputImag = [Float](repeating: 0.0, count: fftSize)
        magSquared = [Float](repeating: 0.0, count: fftSize)
        dbMagnitudes = [Float](repeating: 0.0, count: fftSize)
        finalMagnitudes = [Float](repeating: 0.0, count: fftSize)
        floatSamples = [Float](repeating: 0.0, count: fftSize)
        waterfallData = Array(repeating: spectrum, count: waterfallHeight)
        
    }
    
    deinit { vDSP_destroy_fftsetup(fftSetup) }
    
    // MARK: - Public API
    
    public func setTuningOffset(_ offset: Float) {
            // This is now the ONLY place where we do expensive trigonometry.
            // We calculate the phase increment needed for our new target frequency.
            let clampedOffset = max(0.0, min(1.0, offset))
            self.tuningOffset = clampedOffset
            
            // Calculate the frequency shift in radians per sample.
            // This value will be used by our high-performance VFO.
            self.vfoPhaseIncrement = (clampedOffset - 0.5) * .pi * 2.0
        }
    
    public func setAutoScale(isOn: Bool) { self.autoScaleEnabled = isOn }
    
    public func process(data: Data) {
        pendingDataLock.lock()
        pendingData.append(data)
        pendingDataLock.unlock()
        
        dspQueue.async { self.runDspLoop() }
    }
    
    
    // MARK: - Core DSP Logic
    
    private func runDspLoop() {
            guard !isProcessing else { return }
            isProcessing = true
            
            // Safely move the pending data into our persistent sample buffer
            pendingDataLock.lock()
            sampleBuffer.append(pendingData)
            pendingData = Data()
            pendingDataLock.unlock()
            
            // The total number of I/Q pairs we can process
            let totalSamples = sampleBuffer.count / 2
            let chunksToProcess = totalSamples / fftSize
            
            guard chunksToProcess > 0 else {
                // Not enough data for a full FFT, release the lock and wait for more.
                isProcessing = false
                return
            }
            
            // Convert the necessary amount of data to floats
            let bytesToProcess = chunksToProcess * fftSize * 2
            var floatSamples = [Float](repeating: 0.0, count: bytesToProcess)
            sampleBuffer.prefix(bytesToProcess).withUnsafeBytes {
                vDSP.convertElements(of: $0.bindMemory(to: UInt8.self), to: &floatSamples)
            }
            
            let offset: Float = -127.5; let scale: Float = 1.0 / 127.5
            vDSP.add(offset, floatSamples)
            vDSP.multiply(scale, floatSamples)
            
            // Remove the processed data from the start of the buffer
            sampleBuffer.removeFirst(bytesToProcess)
            
            // Process each chunk
            for i in 0..<chunksToProcess {
                let start = i * fftSize * 2
                let end = start + fftSize * 2
                let chunk = Array(floatSamples[start..<end])

                let fftMagnitudes = performFFT(on: chunk)
                let audioSamples = demodulator.demodulate(frequencyBand: extractFrequencyBand(from: fftMagnitudes))

                audioManager.playSamples(audioSamples)

                guard !fftMagnitudes.isEmpty else { continue }
                averagingBuffer.append(fftMagnitudes)
                if averagingBuffer.count > averagingCount { averagingBuffer.removeFirst() }
            }
            
            // --- FINAL UI UPDATE (Now guaranteed to run if we processed data) ---
            if !averagingBuffer.isEmpty {
                // Compute actual average across all buffers in averagingBuffer
                var averagedMagnitudes = [Float](repeating: 0.0, count: averagingBuffer[0].count)
                for buffer in averagingBuffer {
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
                
                DispatchQueue.main.async {
                    self.spectrum = averagedMagnitudes
                    self.waterfallData.removeLast()
                    self.waterfallData.insert(averagedMagnitudes, at: 0)
                    if self.autoScaleEnabled {
                        self.dynamicMinDb = newMin
                        self.dynamicMaxDb = newMax
                    }
                }
            }
            
            isProcessing = false
        }
    
    public func updateParameters(fftSize: Int, averagingCount: Int, waterfallHeight: Int) {
            // Use a semaphore to ensure parameter updates complete before resuming processing
            let semaphore = DispatchSemaphore(value: 0)

            dspQueue.async {
                // Clear all data buffers
                self.averagingBuffer.removeAll()
                self.pendingDataLock.lock()
                self.pendingData.removeAll()
                self.pendingDataLock.unlock()

                // Update waterfall height if needed
                if waterfallHeight != self.waterfallHeight {
                    self.waterfallHeight = waterfallHeight
                    let emptySpectrum = [Float](repeating: -120.0, count: self.fftSize)
                    self.waterfallData = Array(repeating: emptySpectrum, count: self.waterfallHeight)
                }

                // Update averaging count
                self.averagingCount = averagingCount

                // Re-initialize FFT and all related buffers IF the size changed
                if fftSize != self.fftSize {
                    vDSP_destroy_fftsetup(self.fftSetup)
                    self.fftSize = fftSize

                    let log2n = vDSP_Length(log2(Float(self.fftSize)))
                    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                        fatalError("Failed to create FFT setup during parameter update")
                    }
                    self.fftSetup = setup

                    // Re-allocate all buffers with the new size
                    self.phaseRamp = [Float](repeating: 0.0, count: self.fftSize)
                    self.phasorReal = [Float](repeating: 0.0, count: self.fftSize)
                    self.phasorImag = [Float](repeating: 0.0, count: self.fftSize)
                    self.chunkReal = [Float](repeating: 0.0, count: self.fftSize)
                    self.chunkImag = [Float](repeating: 0.0, count: self.fftSize)
                    self.shiftedReal = [Float](repeating: 0.0, count: self.fftSize)
                    self.shiftedImag = [Float](repeating: 0.0, count: self.fftSize)
                    self.fftInputReal = [Float](repeating: 0.0, count: self.fftSize)
                    self.fftInputImag = [Float](repeating: 0.0, count: self.fftSize)
                    self.fftOutputReal = [Float](repeating: 0.0, count: self.fftSize)
                    self.fftOutputImag = [Float](repeating: 0.0, count: self.fftSize)
                    self.magSquared = [Float](repeating: 0.0, count: self.fftSize)
                    self.dbMagnitudes = [Float](repeating: 0.0, count: self.fftSize)
                    self.finalMagnitudes = [Float](repeating: 0.0, count: self.fftSize)
                    self.realSquared = [Float](repeating: 0.0, count: self.fftSize)
                    self.imagSquared = [Float](repeating: 0.0, count: self.fftSize)

                    // Update published data to the correct size
                    DispatchQueue.main.async {
                        self.spectrum = [Float](repeating: -120.0, count: self.fftSize)
                        self.waterfallData = Array(repeating: self.spectrum, count: self.waterfallHeight)
                    }
                }

                semaphore.signal()
            }

            // Wait for parameter update to complete
            semaphore.wait()
        }
    
    
    // --- HELPER FUNCTIONS ---

    private func extractFrequencyBand(from fftMagnitudes: [Float]) -> [Float] {
        // Calculate the frequency band based on tuning offset and bandwidth
        let centerFrequencyRatio = Double(tuningOffset)
        let bandwidthRatio = vfoBandwidthHz / sampleRateHz

        // Convert ratios to bin indices
        let centerBin = Int(centerFrequencyRatio * Double(fftSize))
        let halfBandwidthBins = Int(bandwidthRatio * Double(fftSize) / 2.0)

        let startBin = max(0, centerBin - halfBandwidthBins)
        let endBin = min(fftSize, centerBin + halfBandwidthBins)

        // Extract the frequency band from the FFT magnitudes
        return Array(fftMagnitudes[startBin..<endBin])
    }
    
    private func performFFT(on samples: [Float]) -> [Float] {
        guard samples.count == fftSize * 2 else { return [] }
        let sampleCount32 = Int32(self.fftSize)

        // --- FIX: Replace de-interleaving loop with cblas_scopy ---
        self.fftInputReal.withUnsafeMutableBufferPointer { realp in
                    self.fftInputImag.withUnsafeMutableBufferPointer { imagp in
                        self.fftOutputReal.withUnsafeMutableBufferPointer { fftOutputRealp in
                            self.fftOutputImag.withUnsafeMutableBufferPointer { fftOutputImagp in
                                
                                // Create DSPSplitComplex structures that vDSP functions require. These are essentially
                                // structs holding pointers to the real and imaginary parts of a complex signal.
                                var input = DSPSplitComplex(realp: realp.baseAddress!, imagp: imagp.baseAddress!)
                                var output = DSPSplitComplex(realp: fftOutputRealp.baseAddress!, imagp: fftOutputImagp.baseAddress!)

                                // --- FIX: Replace deprecated cblas_scopy with vDSP_ctoz ---
                                // This single function de-interleaves the [I, Q, I, Q] samples into separate
                                // real (I) and imaginary (Q) buffers, which is what the FFT needs.
                                // It's more efficient and the correct, modern approach.
                                samples.withUnsafeBytes { (samplesPtr: UnsafeRawBufferPointer) in
                                    let complexPtr = samplesPtr.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                                    vDSP_ctoz(complexPtr, 2, &input, 1, vDSP_Length(self.fftSize))
                                }

                                // Perform the forward FFT.
                                let log2n = vDSP_Length(log2(Float(self.fftSize)))
                                vDSP_fft_zop(fftSetup, &input, 1, &output, 1, log2n, FFTDirection(kFFTDirection_Forward))
                            }
                        }
                    }
                }
        vDSP.square(self.fftOutputReal, result: &self.realSquared)
        vDSP.square(self.fftOutputImag, result: &self.imagSquared)
        vDSP.add(self.realSquared, self.imagSquared, result: &self.magSquared)

        let zero: Float = 0.000001
        vDSP.add(zero, self.magSquared, result: &self.magSquared)
        vDSP.convert(power: self.magSquared, toDecibels: &self.dbMagnitudes, zeroReference: 1.0)

        let halfSize = self.fftSize / 2
        let firstHalf = self.dbMagnitudes[halfSize..<self.fftSize]
        let secondHalf = self.dbMagnitudes[0..<halfSize]
        self.finalMagnitudes.replaceSubrange(0..<halfSize, with: firstHalf)
        self.finalMagnitudes.replaceSubrange(halfSize..<self.fftSize, with: secondHalf)

        return self.finalMagnitudes
    }
    
    
    public func setVFO(bandwidthHz: Double) {
            self.vfoBandwidthHz = bandwidthHz
            // Pass the updated value to the demodulator
            updateDemodulatorParameters()
        }
    public func setSquelch(level: Float) {
            self.squelchLevel = level
            // Pass the updated value to the demodulator
            updateDemodulatorParameters()
        }

    public func setSampleRate(_ sampleRate: Double) {
            self.sampleRateHz = sampleRate
            // Pass the updated value to the demodulator
            updateDemodulatorParameters()
        }
    
    private func updateDemodulatorParameters() {
            demodulator.update(bandwidthHz: vfoBandwidthHz,
                               sampleRateHz: sampleRateHz,
                               squelchLevel: squelchLevel)
        }
    
}
