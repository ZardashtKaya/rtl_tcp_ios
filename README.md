# SDR Connect (Working Title)

`SDR Connect` is a high-performance Software Defined Radio (SDR) client for iOS, built with Swift and SwiftUI. It connects over the network to an `rtl_tcp` server, allowing users to explore the radio spectrum with a real-time spectrogram and waterfall display, tune frequencies, and demodulate signals directly on their iPhone.

This project is currently in the **alpha stage**. The core visualization and NFM demodulation pipelines are functional, but there are known issues and many features yet to be implemented.

## Current State

The app can successfully:
- Connect to an `rtl_tcp` server over the network.
- Receive and process I/Q data in real-time.
- Display a performant, interactive spectrogram and waterfall.
- Control key hardware parameters of the RTL-SDR dongle (frequency, sample rate, gain, AGC, etc.) via a tabbed UI.
- Tune a specific signal using an interactive VFO (Virtual Frequency Oscillator).
- Adjust VFO bandwidth with a pinch gesture.
- Demodulate Narrowband FM (NFM) signals and play the audio through the speaker.
- Adjust an audio squelch level.

## Project File Structure

The project is organized using the **MVVM (Model-View-ViewModel)** architecture to ensure a clean separation of concerns between the UI, state management, and core logic.

```
📁 rtl_tcp/
│
├── 📁 App/
│   └── 📄 rtl_tcpApp.swift
│
├── 📁 Features/
│   └── 📁 Radio/
│       ├── 📂 View/
│       │   ├── 📄 RadioView.swift
│       │   ├── 📂 Controls/
│       │   │   ├── 📄 ConnectionSettingsView.swift
│       │   │   ├── 📄 ConnectionStatusView.swift
│       │   │   ├── 📄 DSPControlsView.swift
│       │   │   ├── 📄 HardwareControlsView.swift
│       │   │   └── 📄 TuningControlsView.swift
│       │
│       └── 📂 ViewModel/
│           └── 📄 RadioViewModel.swift
├── 📁 Bookmarks //TODO
        |   ├── 📂 View //TODO
        |   |   ├── 📄 BookmarksListView.swift     // Displays the list of saved frequencies. //TODO
        |   |   ├── 📄 BookmarkDetailView.swift    // View for adding/editing a bookmark. //TODO
        |   |
        |   ├── 📂 ViewModel //TODO
        |       ├── 📄 BookmarksViewModel.swift    // Manages the logic for fetching and saving bookmarks. //TODO
│
├── 📁 Core/
│   ├── 📁 Networking/
│   │   └── 📄 RTLTCPClient.swift
│   │
│   ├── 📁 DSP/
│   │   ├── 📄 DSPEngine.swift
│   │   ├── 📄 SpectrogramProcessor.swift //TODO
│   │   ├── 📄 VFOProcessor.swift  //TODO
│   │   ├── 📄 CircularBuffer.swift //TODO
│   │   └── 📂 Demodulators/
│   │       ├── 📄 Demodulator.swift
│   │       ├── 📄 WFMDemodulator.swift //TODO
│   │       ├── 📄 NFM_AM_Demodulator.swift //TODO
│   │       ├── 📄 SSBDemodulator.swift //TODO
│   │       ├── 📄 RAWDemodulator.swift //TODO
│   │       └── 📄 NFMDemodulator.swift
│   │
│   └── 📁 Audio/
│       └── 📄 AudioManager.swift
│
├── 📁 Data/
│   ├── 📄 RadioSettings.swift
│   └── 📄 SampleRate.swift
│
└── 📁 UI Components/
    ├── 📄 FrequencyDialView.swift
    ├── 📄 SpectrogramView.swift
    ├── 📄 TuningIndicatorView.swift
    └── 📄 WaterfallView.swift
```

## Known Issues & TODO List

This list tracks the next steps for development and bug fixes.

### 🟥 Critical Bugs & Performance Issues
-   **[TODO] DSP Performance:** The `performVFO` and `performFFT` functions still rely on some manual Swift `for` loops for data manipulation (re-interleaving). Profiling shows these `IndexingIterator` calls are a major bottleneck. These loops must be replaced with highly-optimized C-based functions from the `Accelerate` framework (like `cblas_scopy` or `vDSP_ztoc`) to achieve maximum performance and reduce battery drain.

### 🟨 High-Priority Features
-   **[TODO] Implement a Real Low-Pass Filter:** The `lowPassFilter` function in `NFMDemodulator.swift` is currently a placeholder. A proper FIR (Finite Impulse Response) filter needs to be designed and implemented. This is the **most important** step for improving audio quality, as it will reject adjacent channel noise before demodulation.
-   **[TODO] Add More Demodulation Modes:**
-   **[TODO] Audio Resampling:** The NFM demodulator currently outputs audio at a sample rate close to 48 KHz but not exactly. A proper audio resampler (e.g., a polyphase FIR filter) should be implemented to convert the demodulated audio stream to the exact `48000.0` Hz required by the `AudioManager` for the highest quality audio playback.
-   **[TODO] Dynamic Sample Rate in DSP:** The `DSPEngine` and `Demodulator` classes have the device's sample rate hardcoded. This needs to be dynamically passed down from the `RadioView` so that the decimation and filter calculations are always correct for the user's selected sample rate.

### 🟦 Medium-Priority Features & UI Polish
-   **[TODO] Frequency Bookmarking:**
    -   Implement `SwiftData` or `CoreData` to store frequency bookmarks.
    -   Build the UI screens (list, add/edit) for managing bookmarks.
-   **[TODO] Scanning Functionality:** Add logic to scan through a list of bookmarked frequencies, stopping when the squelch opens.
-   **[TODO] Custom Frequency Step:** The "Custom..." button on the frequency dial is a placeholder. This should present a dialog or text field to allow the user to input a custom tuning step value.
-   **[TODO] More Robust Connection Logic:** The `DispatchQueue.main.asyncAfter` call in `RadioViewModel`'s `setupAndConnect` is a "hack". This should be replaced with a more robust Combine-based approach that waits for the `client.isConnected` property to become `true` before sending the initial batch of commands.

###    Low-Priority & Future Ideas
-   **[TODO] Windowing Function:** Apply a windowing function (e.g., Hann or Blackman-Harris) to the I/Q data before the FFT in `performFFT`. This will reduce spectral leakage and result in a cleaner, more accurate spectrogram with less "smearing" of strong signals.
-   **[TODO] Multiple VFOs:** Refactor the `DSPEngine` to support multiple independent VFO processing chains to demodulate more than one signal within the captured bandwidth simultaneously.
