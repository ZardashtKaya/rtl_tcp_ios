//
//  SampleRate.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation

// Conform to CaseIterable to easily list all options in the UI.
// Conform to Identifiable so it can be used in a Picker.
enum SampleRate: UInt32, CaseIterable, Identifiable {
    case khz250   = 250000
    case mhz1_024 = 1024000
    case mhz1_536 = 1536000
    case mhz1_792 = 1792000
    case mhz1_92  = 1920000
    case mhz2_048 = 2048000
    case mhz2_16  = 2160000
    case mhz2_4   = 2400000
    case mhz2_56  = 2560000
    case mhz2_88  = 2880000
    case mhz3_2   = 3200000
    
    // The id for the Picker needs to be stable. The rawValue is perfect for this.
    var id: UInt32 { self.rawValue }
    
    // A user-friendly string representation for the UI.
    var stringValue: String {
        switch self {
        case .khz250:   return "250 KHz"
        case .mhz1_024: return "1.024 MHz"
        case .mhz1_536: return "1.536 MHz"
        case .mhz1_792: return "1.792 MHz"
        case .mhz1_92:  return "1.92 MHz"
        case .mhz2_048: return "2.048 MHz"
        case .mhz2_16:  return "2.16 MHz"
        case .mhz2_4:   return "2.4 MHz"
        case .mhz2_56:  return "2.56 MHz"
        case .mhz2_88:  return "2.88 MHz"
        case .mhz3_2:   return "3.2 MHz"
        }
    }
}
