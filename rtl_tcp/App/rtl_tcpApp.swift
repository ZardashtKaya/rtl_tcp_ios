//
//  App/rtl_tcpApp.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

@main
struct rtl_tcpApp: App {
    init() {
        print("🚀 App init started: \(Date())")
    }
    
    var body: some Scene {
        WindowGroup {
            RadioView()
                .onAppear {
                    print("🎯 RadioView appeared: \(Date())")
                }
        }
    }
}
