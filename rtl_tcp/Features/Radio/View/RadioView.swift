//
//  Features/Radio/View/View/RadioView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//
import SwiftUI

struct RadioView: View {
    // MARK: - State Properties
    
    // The View now has only ONE source of truth: the ViewModel.
    @StateObject private var viewModel = RadioViewModel()
    @State private var isLoading = true
    
    // Connection settings remain as simple @State for the TextFields.
    @State private var host: String = "zardashtmac.local"
    @State private var port: String = "1234"
    
    // Gesture-specific state MUST remain in the View.
    @GestureState private var dragAmount: CGFloat = 0
    @GestureState private var magnificationAmount: CGFloat = 1.0
    @FocusState private var isFrequencyFieldFocused: Bool
    @State private var showConnectionSettings = false


    // MARK: - Main Body
    
    var body: some View {
            NavigationView {
                if isLoading {
                    ProgressView("Initializing...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else {
                    VStack(spacing: 4) {
                        interactiveDisplayArea
                        controlsTabView
                    }
                    .padding(.vertical)
                    .background(Color.black.edgesIgnoringSafeArea(.all))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button(action: {
                                showConnectionSettings = true
                            }) {
                                ConnectionStatusView(isConnected: viewModel.client.isConnected)
                            }
                            .popover(isPresented: $showConnectionSettings) {
                                ConnectionSettingsView(
                                    viewModel: viewModel,
                                    host: $host,
                                    port: $port,
                                    isPresented: $showConnectionSettings
                                )
                                .presentationCompactAdaptation(.popover)
                            }
                        }
                    }
                }
            }
            .navigationViewStyle(.stack)
            .preferredColorScheme(.dark)
            .onAppear {
                // ----> FIX: Delay to allow initialization <----
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isLoading = false
                }
            }
        }
    
    // MARK: - Subviews
    
    private var interactiveDisplayArea: some View {
        ZStack {
            VStack(spacing: 4) {
                let currentMin = viewModel.isAutoScaleEnabled ? viewModel.dspEngine.dynamicMinDb : viewModel.manualMinDb
                let currentMax = viewModel.isAutoScaleEnabled ? viewModel.dspEngine.dynamicMaxDb : viewModel.manualMaxDb
                
                SpectrogramView(data: viewModel.dspEngine.spectrum, minDb: currentMin, maxDb: currentMax)
                    .background(Color.black).cornerRadius(8)
                
                WaterfallView(data: viewModel.dspEngine.waterfallData, minDb: currentMin, maxDb: currentMax)
                    .background(Color.black).cornerRadius(8).frame(height: 200)
            }
            
            TuningIndicatorView(
                tuningOffset: viewModel.tuningOffset + dragAmount,
                bandwidthHz: viewModel.vfoBandwidthHz * magnificationAmount,
                sampleRateHz: Double(viewModel.selectedSampleRate.rawValue)
            )
            
            GeometryReader { geometry in
                let squelchY = geometry.size.height * (1.0 - CGFloat(viewModel.squelchLevel))
                Path { path in
                    path.move(to: CGPoint(x: 0, y: squelchY))
                    path.addLine(to: CGPoint(x: geometry.size.width, y: squelchY))
                }
                .stroke(Color.yellow.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [5]))
            }
        }
        .padding(.horizontal)
        .gesture(displayAreaGestures)
    }
    
    private var controlsTabView: some View {
        TabView {
                TuningControlsView(
                    squelchLevel: $viewModel.squelchLevel,
                    frequencyMHz: $viewModel.settings.frequencyMHz,
                    frequencyStep: $viewModel.frequencyStep,
                    isFrequencyFieldFocused: $isFrequencyFieldFocused,
                    vfoBandwidthHz: $viewModel.vfoBandwidthHz,
                    viewModel: viewModel  // Add this line
                )
                .tabItem { Image(systemName: "tuningfork"); Text("Tuning") }
            
            DSPControlsView(
                isAutoScaleEnabled: $viewModel.isAutoScaleEnabled,
                manualMinDb: $viewModel.manualMinDb,
                manualMaxDb: $viewModel.manualMaxDb,
                selectedFFTSize: $viewModel.selectedFFTSize,
                averagingCount: $viewModel.averagingCount,
                waterfallHeight: $viewModel.waterfallHeight
            )
            .tabItem { Image(systemName: "dial.medium"); Text("DSP") }
            
            HardwareControlsView(
                settings: $viewModel.settings,
                selectedSampleRate: $viewModel.selectedSampleRate
            )
            .tabItem { Image(systemName: "memorychip"); Text("Hardware") }
        }
    }
    
    private var connectionStatusArea: some View {
        VStack {
            HStack {
                Circle().frame(width: 20, height: 20).foregroundColor(viewModel.client.isConnected ? .green : .red)
                Text(viewModel.client.isConnected ? "Connected" : "Disconnected")
            }
            .padding(.top, 5)

            HStack(spacing: 30) {
                Button("Connect") { viewModel.setupAndConnect(host: host, port: port) }
                    .font(.title2)
                    .disabled(viewModel.client.isConnected)
                
                Button("Disconnect") { viewModel.client.disconnect() }
                    .font(.title2)
                    .disabled(!viewModel.client.isConnected)
            }
        }
    }
    
    private var displayAreaGestures: some Gesture {
        let magnificationGesture = MagnificationGesture()
            .updating($magnificationAmount) { value, state, _ in state = value }
            .onEnded { value in
                viewModel.vfoBandwidthHz *= Double(value)
                viewModel.vfoBandwidthHz = max(5_000, min(250_000, viewModel.vfoBandwidthHz))
            }

        let dragGesture = DragGesture()
            .updating($dragAmount) { value, state, _ in
                state = value.translation.width / UIScreen.main.bounds.width
            }
            .onEnded { value in
                let dragOffset = value.translation.width / UIScreen.main.bounds.width
                viewModel.tuningOffset += dragOffset
                viewModel.tuningOffset = max(0.0, min(1.0, viewModel.tuningOffset))
            }
        
        return magnificationGesture.simultaneously(with: dragGesture)
    }
}
