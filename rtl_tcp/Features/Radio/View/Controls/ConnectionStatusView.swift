//
//  Features/Radio/View/Controls/ConnectionStatusView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

struct ConnectionStatusView: View {
    let isConnected: Bool
    
    var body: some View {
        HStack {
            Circle()
                .frame(width: 20, height: 20)
                .foregroundColor(isConnected ? .green : .red)
                .shadow(color: (isConnected ? Color.green : Color.red).opacity(0.5), radius: 5)
                // ----> ADD: Animation <----
                .scaleEffect(isConnected ? 1.0 : 0.8)
                .animation(.easeInOut(duration: 0.3), value: isConnected)
            
            Text(isConnected ? "Connected" : "Disconnected")
                .font(.headline)
                .foregroundColor(isConnected ? .green : .red)
                // ----> ADD: Animation <----
                .animation(.easeInOut(duration: 0.3), value: isConnected)
        }
    }
}
