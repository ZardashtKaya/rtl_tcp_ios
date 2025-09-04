//
//  ConnectionStatusView.swift
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
            
            Text(isConnected ? "Connected" : "Disconnected")
                .font(.headline)
        }
    }
}
