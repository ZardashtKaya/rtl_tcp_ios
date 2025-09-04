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
    private var floatSamples: [Float]
    private var phaseRamp: [Float]
    private var phasorReal, phasorImag, chunkReal, chunkImag, shiftedReal, shiftedImag: [Float]
    private var fftInputReal: [Float]
    private var fftInputImag: [Float]
    private var fftOutputReal: [Float]
    private var fftOutputImag: [Float]
    private var magSquared: [Float]
    private var dbMagnitudes: [Float]
    private var finalMagnitudes: [Float]
    
    private var demodulator: Demodulator
    private let audioManager = AudioManager()
    private var vfoBandwidthHz: Double = 12_500.0
       private var squelchLevel: Float = 0.2
    
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
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        
        spectrum = [Float](repeating: -120.0, count: fftSize)
        
        floatSamples = [Float](repeating: 0.0, count: 65536)
        phaseRamp = [Float](repeating: 0.0, count: fftSize)
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
                
                let shiftedSamples = performVFO(on: chunk)
                let fftMagnitudes = performFFT(on: shiftedSamples) // Use shifted for centered display
                let audioSamples = demodulator.demodulate(iqSamples: shiftedSamples)
                
                audioManager.playSamples(audioSamples)
                
                guard !fftMagnitudes.isEmpty else { continue }
                averagingBuffer.append(fftMagnitudes)
                if averagingBuffer.count > averagingCount { averagingBuffer.removeFirst() }
            }
            
            // --- FINAL UI UPDATE (Now guaranteed to run if we processed data) ---
            if !averagingBuffer.isEmpty {
                var averagedMagnitudes = averagingBuffer.last! // Use the most recent average
                
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
            // Run this on the DSP queue to prevent race conditions.
            dspQueue.async {
                // Stop any ongoing processing
                self.isProcessing = true
                
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
                    self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
                    
                    // Re-allocate all buffers with the new size
                    self.phaseRamp = [Float](repeating: 0.0, count: self.fftSize)
                    self.phasorReal = [Float](repeating: 0.0, count: self.fftSize)
                    // ... (re-allocate all other buffers) ...
                    self.phasorImag = [Float](repeating: 0.0, count: self.fftSize); self.chunkReal = [Float](repeating: 0.0, count: self.fftSize); self.chunkImag = [Float](repeating: 0.0, count: self.fftSize); self.shiftedReal = [Float](repeating: 0.0, count: self.fftSize); self.shiftedImag = [Float](repeating: 0.0, count: self.fftSize); self.fftInputReal = [Float](repeating: 0.0, count: self.fftSize); self.fftInputImag = [Float](repeating: 0.0, count: self.fftSize); self.fftOutputReal = [Float](repeating: 0.0, count: self.fftSize); self.fftOutputImag = [Float](repeating: 0.0, count: self.fftSize); self.magSquared = [Float](repeating: 0.0, count: self.fftSize); self.dbMagnitudes = [Float](repeating: 0.0, count: self.fftSize); self.finalMagnitudes = [Float](repeating: 0.0, count: self.fftSize)
                    
                    // Update published data to the correct size
                    DispatchQueue.main.async {
                        self.spectrum = [Float](repeating: -120.0, count: self.fftSize)
                        self.waterfallData = Array(repeating: self.spectrum, count: self.waterfallHeight)
                    }
                }
                
                // Re-enable processing
                self.isProcessing = false
            }
        }
    
    
    // --- HELPER FUNCTIONS MOVED BACK TO CLASS SCOPE ---
    
    private func performVFO(on samples: [Float]) -> [Float] {
        let sampleCount = self.fftSize
        let sampleCount32 = Int32(sampleCount)
        
        // Phase calculation...
        vDSP_vramp(&self.vfoPhase, &self.vfoPhaseIncrement, &self.phaseRamp, 1, vDSP_Length(sampleCount))
        self.vfoPhase = self.phaseRamp[sampleCount - 1].truncatingRemainder(dividingBy: 2 * .pi)
        var N: Int32 = sampleCount32
        vvcosf(&self.phasorReal, &self.phaseRamp, &N)
        vvsinf(&self.phasorImag, &self.phaseRamp, &N)
        
        // Optimized De-interleaving (The big performance win)
        cblas_scopy(sampleCount32, samples, 2, &self.chunkReal, 1)
        samples.withUnsafeBufferPointer { samplesBuffer in
            let imaginarySamplesPointer = samplesBuffer.baseAddress!.advanced(by: 1)
            cblas_scopy(sampleCount32, imaginarySamplesPointer, 2, &self.chunkImag, 1)
        }
        
        // Complex Multiplication...
        var chunkSplitComplex = DSPSplitComplex(realp: &self.chunkReal, imagp: &self.chunkImag)
        var phasorSplitComplex = DSPSplitComplex(realp: &self.phasorReal, imagp: &self.phasorImag)
        var shiftedSplitComplex = DSPSplitComplex(realp: &self.shiftedReal, imagp: &self.shiftedImag)
        vDSP_zvmul(&chunkSplitComplex, 1, &phasorSplitComplex, 1, &shiftedSplitComplex, 1, vDSP_Length(sampleCount), 1)
        
        // Simple, compiling re-interleaving loop.
        var shiftedSamples = [Float](repeating: 0.0, count: samples.count)
        for i in 0..<sampleCount {
            shiftedSamples[i * 2] = self.shiftedReal[i]
            shiftedSamples[i * 2 + 1] = self.shiftedImag[i]
        }

        return shiftedSamples
    }
    
    private func performFFT(on samples: [Float]) -> [Float] {
        guard samples.count == fftSize * 2 else { return [] }
        let sampleCount32 = Int32(self.fftSize)

        // --- FIX: Replace de-interleaving loop with cblas_scopy ---
        cblas_scopy(sampleCount32, samples, 2, &self.fftInputReal, 1)
        samples.withUnsafeBufferPointer { samplesBuffer in
            let imaginarySamplesPointer = samplesBuffer.baseAddress!.advanced(by: 1)
            cblas_scopy(sampleCount32, imaginarySamplesPointer, 2, &self.fftInputImag, 1)
        }
        
        // The rest of the FFT process is the same, using the now-populated buffers
        self.fftInputReal.withUnsafeMutableBufferPointer { realp in
            self.fftInputImag.withUnsafeMutableBufferPointer { imagp in
                self.fftOutputReal.withUnsafeMutableBufferPointer { fftOutputRealp in
                    self.fftOutputImag.withUnsafeMutableBufferPointer { fftOutputImagp in
                        var input = DSPSplitComplex(realp: realp.baseAddress!, imagp: imagp.baseAddress!)
                        var output = DSPSplitComplex(realp: fftOutputRealp.baseAddress!, imagp: fftOutputImagp.baseAddress!)
                        let log2n = vDSP_Length(log2(Float(self.fftSize)))
                        vDSP_fft_zop(fftSetup, &input, 1, &output, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    }
                }
            }
        }
        
        var realSquared = [Float](repeating: 0.0, count: fftSize)
            vDSP.square(self.fftOutputReal, result: &realSquared)
            var imagSquared = [Float](repeating: 0.0, count: fftSize)
            vDSP.square(self.fftOutputImag, result: &imagSquared)
            vDSP.add(realSquared, imagSquared, result: &self.magSquared)
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
    
    private func updateDemodulatorParameters() {
            // TODO: Pass the real sample rate from RadioView here
            let currentSampleRate = 2_048_000.0
            demodulator.update(bandwidthHz: vfoBandwidthHz,
                               sampleRateHz: currentSampleRate,
                               squelchLevel: squelchLevel)
        }
    
}
