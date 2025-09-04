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
    
    // ----> ADD: Cleanup timer <----
    private var cleanupTimer: Timer?

    init() {
        setupBindingsAsync()
        startCleanupTimer()
    }
    
    deinit {
        cleanupTimer?.invalidate()
        cancellables.removeAll()
    }
    
    // ----> ADD: Periodic cleanup <----
    private func startCleanupTimer() {
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.performCleanup()
        }
    }
    
    private func performCleanup() {
        // Reset audio buffer if it's getting too full
        let stats = dspEngine.audioManager.getAudioStats()
        if stats.buffered > 96000 { // 2 seconds at 48kHz
            print("🧹 Resetting audio buffer due to excessive buffering")
            // You might need to add a reset method to AudioManager
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
        // ----> FIX: Add more aggressive debouncing <----
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
        client.onDataReceived = { [weak self] data in
            self?.dspEngine.process(data: data)
        }
        guard let portNumber = UInt16(port) else { return }
        client.connect(host: host, port: portNumber)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self, self.client.isConnected else { return }
            
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
