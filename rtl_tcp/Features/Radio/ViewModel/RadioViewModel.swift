//
//  Features/Radio/ViewModel/RadioViewModel.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation
import Combine

class RadioViewModel: ObservableObject {
    @Published var client = RTLTCPClient()
    @Published var dspEngine = DSPEngine()
    
    @Published var settings = RadioSettings()
    @Published var selectedSampleRate: SampleRate = .mhz2_048
    
    @Published var isAutoScaleEnabled: Bool = true
    @Published var manualMinDb: Float = -100.0
    @Published var manualMaxDb: Float = 0.0
    
    @Published var selectedFFTSize: Int = 4096
    @Published var averagingCount: Int = 10
    @Published var waterfallHeight: Int = 200
    
    @Published var tuningOffset: CGFloat = 0.5
    @Published var vfoBandwidthHz: Double = 12_500.0
    @Published var squelchLevel: Float = 0.2
    @Published var frequencyStep: FrequencyStep = .khz100
    
    private var cancellables = Set<AnyCancellable>()
    private var cleanupTimer: Timer?
    
    // ----> ADD: Connection state tracking <----
    @Published var isConnected: Bool = false

    init() {
        setupBindingsAsync()
        startCleanupTimer()
        setupConnectionObserver()
    }
    
    deinit {
        cleanupTimer?.invalidate()
        cancellables.removeAll()
    }
    
    // ----> ADD: Connection state observer <----
    private func setupConnectionObserver() {
        client.$isConnected
            .removeDuplicates()
            .sink { [weak self] connected in
                self?.isConnected = connected
                if connected {
                    self?.handleConnectionEstablished()
                } else {
                    self?.handleConnectionLost()
                }
            }
            .store(in: &cancellables)
    }
    
    // ----> ADD: Connection established handler <----
    private func handleConnectionEstablished() {
        print("🔗 Connection established - initializing audio system...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Reset DSP engine and audio system
            self.dspEngine.resetForConnection()
            
            // Reset demodulator if it has a reset method
            if let nfmDemod = self.dspEngine.demodulator as? NFMDemodulator {
                nfmDemod.resetForConnection()
            }
            
            print("🔗 Audio system initialized for connection")
        }
    }
    
    // ----> ADD: Connection lost handler <----
    private func handleConnectionLost() {
        print("🔗 Connection lost - stopping audio system...")
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Stop DSP engine and audio system
            self.dspEngine.stopForDisconnection()
            
            print("🔗 Audio system stopped for disconnection")
        }
    }
    
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
    }
    
    private func performCleanup() {
        let stats = dspEngine.audioManager.getAudioStats()
        if stats.buffered > 96000 {
            print("🧹 Resetting audio buffer due to excessive buffering")
        }
        
        print("🧹 Cleanup: Audio buffered=\(stats.buffered), underruns=\(stats.underruns)")
    }
    
    public func testDemodulation() {
        dspEngine.testDemodulationChain()
    }
    
    public func playTestAudio(_ samples: [Float]) {
        dspEngine.audioManager.playSamples(samples)
    }
    
    public func getAudioStats() {
        dspEngine.audioManager.debugAudioPipeline()
    }
    
    private func setupBindingsAsync() {
        DispatchQueue.main.async { [weak self] in
            self?.setupBindings()
        }
    }
    
    private func setupBindings() {
        $settings
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] newSettings in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.updateClientSettings(newSettings)
                }
            }
            .store(in: &cancellables)
        
        $selectedSampleRate
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] rate in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.client.setSampleRate(rate.rawValue)
                }
            }
            .store(in: &cancellables)
        
        $isAutoScaleEnabled
            .removeDuplicates()
            .sink { [weak self] enabled in
                self?.dspEngine.setAutoScale(isOn: enabled)
            }
            .store(in: &cancellables)
        
        $tuningOffset
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] offset in
                self?.dspEngine.setTuningOffset(Float(offset))
            }
            .store(in: &cancellables)
        
        $vfoBandwidthHz
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] bandwidth in
                self?.dspEngine.setVFO(bandwidthHz: bandwidth)
            }
            .store(in: &cancellables)
        
        $squelchLevel
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] level in
                self?.dspEngine.setSquelch(level: level)
            }
            .store(in: &cancellables)
        
        Publishers.CombineLatest3($selectedFFTSize, $averagingCount, $waterfallHeight)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] fft, avg, height in
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.callUpdateParameters(fftSize: fft, averagingCount: avg, waterfallHeight: height)
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateClientSettings(_ settings: RadioSettings) {
        client.setFrequency(UInt32(settings.frequencyMHz * 1_000_000))
        client.setAgcMode(isOn: settings.isAgcOn)
        client.setBiasTee(isOn: settings.isBiasTeeOn)
        client.setOffsetTuning(isOn: settings.isOffsetTuningOn)
        if !settings.isAgcOn {
            client.setTunerGain(byIndex: settings.tunerGainIndex)
        }
    }
    
    func setupAndConnect(host: String, port: String) {
        // ----> FIX: Set up data handler before connecting <----
        client.onDataReceived = { [weak self] data in
            self?.dspEngine.process(data: data)
        }
        
        guard let portNumber = UInt16(port) else { return }
        client.connect(host: host, port: portNumber)
        
        // ----> FIX: Wait for connection and initialization <----
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.client.isConnected else { return }
            
            print("🔗 Sending initial configuration...")
            
            self.client.setSampleRate(self.selectedSampleRate.rawValue)
            self.client.setFrequency(UInt32(self.settings.frequencyMHz * 1_000_000))
            self.client.setAgcMode(isOn: self.settings.isAgcOn)
            if !self.settings.isAgcOn {
                self.client.setTunerGain(byIndex: self.settings.tunerGainIndex)
            }
            self.client.setBiasTee(isOn: self.settings.isBiasTeeOn)
            self.client.setOffsetTuning(isOn: self.settings.isOffsetTuningOn)
            self.dspEngine.setVFO(bandwidthHz: self.vfoBandwidthHz)
            self.dspEngine.setSquelch(level: self.squelchLevel)
            
            print("🔗 Initial configuration sent")
        }
    }
    
    private func callUpdateParameters(fftSize: Int, averagingCount: Int, waterfallHeight: Int) {
        dspEngine.updateParameters(
            fftSize: fftSize,
            averagingCount: averagingCount,
            waterfallHeight: waterfallHeight
        )
    }
}
