//
//  Features/Radio/View/Controls/ConnectionSettingsView.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import SwiftUI

struct ConnectionSettingsView: View {
    // We receive the ViewModel and local state via bindings.
    @ObservedObject var viewModel: RadioViewModel
    @Binding var host: String
    @Binding var port: String
    
    // A binding to the popover's presentation state, so we can dismiss it.
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text("Connection")
                .font(.headline)
            
            TextField("Host Address", text: $host)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            
            TextField("Port", text: $port)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .keyboardType(.numberPad)
            
            Divider()
            
            if viewModel.client.isConnected {
                Button("Disconnect") {
                    viewModel.client.disconnect()
                    isPresented = false // Dismiss the popover on action
                }
                .font(.title2)
                .foregroundColor(.red)
            } else {
                Button("Connect") {
                    viewModel.setupAndConnect(host: host, port: port)
                    isPresented = false // Dismiss the popover on action
                }
                .font(.title2)
            }
        }
        .padding()
        .frame(width: 300, height: 250) // Adjusted height for a more compact view
    }
}
