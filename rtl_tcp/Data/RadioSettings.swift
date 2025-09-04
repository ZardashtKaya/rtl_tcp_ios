//
//  RadioSettings.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation

struct RadioSettings {
    // Default to a common FM radio station frequency
    var frequencyMHz: Double = 433.0

    
    // RTL-SDRv3 has 29 gain steps (0-28)
    var tunerGainIndex: Int = 28
    
    var isAgcOn: Bool = false
    var isBiasTeeOn: Bool = false
    var isOffsetTuningOn: Bool = false
    var RTLGainMode: Bool = false
}
