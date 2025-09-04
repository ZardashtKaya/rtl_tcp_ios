//
//  Core/Networking/RTLTCPClient.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//


import Foundation
import Combine
import Network

// Now, the compiler knows what ObservableObject and @Published mean.
class RTLTCPClient: ObservableObject {
    
    @Published var isConnected: Bool = false
    
    //DEBUG
    //@Published var bytesReceived: Int = 0

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.zardashtkaya.rtltcp.client")
    var onDataReceived: ((Data) -> Void)?


    // ... the rest of your code for connect(), disconnect(), etc.
    // (The rest of the code from the previous step is correct)
    func connect(host: String, port: UInt16) {
        let hostEndpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(rawValue: port)!
        connection = NWConnection(host: hostEndpoint, port: portEndpoint, using: .tcp)

        connection?.stateUpdateHandler = { [weak self] newState in
            DispatchQueue.main.async {
                switch newState {
                case .ready:
                    self?.isConnected = true
                    print("✅ Connection Ready")
                    self?.receive()
                case .failed(let error):
                    print("❌ Connection Failed: \(error.localizedDescription)")
                    self?.isConnected = false
                    self?.connection = nil
                case .cancelled:
                    print("- Connection Cancelled")
                    self?.isConnected = false
                    self?.connection = nil
                default:
                    break
                }
            }
        }
        connection?.start(queue: queue)
    }

    func disconnect() {
        connection?.cancel()
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] (data, context, isComplete, error) in
            if let receivedData = data, !receivedData.isEmpty {
                // ----> ADD: Debug logging <----
//                print("📡 Received \(receivedData.count) bytes")
                self?.onDataReceived?(receivedData)
            }
            if let error = error {
                print("❌ Receive error: \(error.localizedDescription)")
                self?.disconnect()
            } else if isComplete {
                print("- Connection closed by server.")
                self?.disconnect()
            } else {
                self?.receive()
            }
        }
    }
    
    private func sendBinaryCommand(commandCode: UInt8, parameter: UInt32) {
            guard isConnected else { return }
            
            // 1. Create a mutable Data object to build our 5-byte command.
            var commandData = Data()
            
            // 2. Append the 1-byte command code.
            commandData.append(commandCode)
            
            // 3. Convert the parameter to big-endian (network byte order). THIS IS CRITICAL.
            var bigEndianParameter = parameter.bigEndian
            
            // 4. Append the 4 bytes of the parameter.
            commandData.append(Data(bytes: &bigEndianParameter, count: MemoryLayout<UInt32>.size))
            
            // 5. Send the final 5-byte data object.
            connection?.send(content: commandData, completion: .contentProcessed({ error in
                if let error = error {
                    print("❌ Send error: \(error.localizedDescription)")
                }
            }))
        }
        

    
    func setFrequency(_ hertz: UInt32) {
           sendBinaryCommand(commandCode: 0x01, parameter: hertz)
       }
       
       // Note: The C code for 'set tuner gain by index' also calls 'set gain mode 1'.
       // We will do the same for correctness.
       func setTunerGain(byIndex index: Int) {
           sendBinaryCommand(commandCode: 0x03, parameter: 1) // Set Gain Mode to Manual
           sendBinaryCommand(commandCode: 0x0d, parameter: UInt32(index))
       }
       
       func setAgcMode(isOn: Bool) {
           let mode: UInt32 = isOn ? 1 : 0
           sendBinaryCommand(commandCode: 0x08, parameter: mode)
           // It's good practice to set gain mode to auto when AGC is on.
           let gainMode: UInt32 = isOn ? 0 : 1
           sendBinaryCommand(commandCode: 0x03, parameter: gainMode)
       }
       
       func setBiasTee(isOn: Bool) {
           let mode: UInt32 = isOn ? 1 : 0
           sendBinaryCommand(commandCode: 0x0e, parameter: mode)
       }
       
       func setOffsetTuning(isOn: Bool) {
           let mode: UInt32 = isOn ? 1 : 0
           sendBinaryCommand(commandCode: 0x0a, parameter: mode)
       }

    func setSampleRate(_ hertz: UInt32) {
            sendBinaryCommand(commandCode: 0x02, parameter: hertz)
        }
    
}
