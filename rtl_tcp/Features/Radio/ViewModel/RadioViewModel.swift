//
//  Features/Radio/ViewModel/RadioViewModel.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation
import Combine // Import Combine for observing state changes

class RadioViewModel: ObservableObject {
    // MARK: - Core Services
    @Published var client = RTLTCPClient()
    @Published var dspEngine = DSPEngine()
    
    // MARK: - Published State Properties
    // All the @State variables from the View are now @Published here.
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
    
    // To store the Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initializer
    init() {
        // This is the replacement for the long .onChange modifier chain.
        // We subscribe to changes in our own properties and trigger the appropriate actions.
        
        $settings
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main) // Prevent sending too many commands
            .sink { [weak self] newSettings in
                self?.client.setFrequency(UInt32(newSettings.frequencyMHz * 1_000_000))
                self?.client.setAgcMode(isOn: newSettings.isAgcOn)
                self?.client.setBiasTee(isOn: newSettings.isBiasTeeOn)
                self?.client.setOffsetTuning(isOn: newSettings.isOffsetTuningOn)
                if !newSettings.isAgcOn {
                    self?.client.setTunerGain(byIndex: newSettings.tunerGainIndex)
                }
            }
            .store(in: &cancellables)
            
        $selectedSampleRate
            .sink { [weak self] rate in self?.client.setSampleRate(rate.rawValue) }
            .store(in: &cancellables)
            
        $isAutoScaleEnabled
            .sink { [weak self] enabled in self?.dspEngine.setAutoScale(isOn: enabled) }
            .store(in: &cancellables)
            
        $tuningOffset
            .sink { [weak self] offset in self?.dspEngine.setTuningOffset(Float(offset)) }
            .store(in: &cancellables)
            
        $vfoBandwidthHz
            .sink { [weak self] bandwidth in self?.dspEngine.setVFO(bandwidthHz: bandwidth) }
            .store(in: &cancellables)
            
        $squelchLevel
            .sink { [weak self] level in self?.dspEngine.setSquelch(level: level) }
            .store(in: &cancellables)
            
        // Combine the DSP parameters to trigger a single update
        Publishers.CombineLatest3($selectedFFTSize, $averagingCount, $waterfallHeight)
            .sink { [weak self] fft, avg, height in
                self?.callUpdateParameters(fftSize: fft, averagingCount: avg, waterfallHeight: height)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods (formerly in the View)
    
    func setupAndConnect(host: String, port: String) {
        client.onDataReceived = { [weak self] data in
            self?.dspEngine.process(data: data)
        }
        guard let portNumber = UInt16(port) else { return }
        client.connect(host: host, port: portNumber)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard client.isConnected else { return }
            
            // Send initial values
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
