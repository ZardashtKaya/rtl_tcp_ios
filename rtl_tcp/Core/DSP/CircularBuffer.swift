//
//  Core/DSP/CircularBuffer.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation

class CircularBuffer {
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let bufferSize: Int
    private let bufferMask: Int
    private let lock = NSLock()
    
    private var overflowCount = 0
    private let maxOverflows = 100

    var availableForReading: Int {
        lock.lock()
        defer { lock.unlock() }
        return (writeIndex - readIndex + bufferSize) & bufferMask
    }

    init(size: Int) {
        let powerOf2Size = 1 << Int(ceil(log2(Double(size))))
        self.bufferSize = powerOf2Size
        self.bufferMask = powerOf2Size - 1
        self.buffer = [Float](repeating: 0.0, count: powerOf2Size)
    }

    @discardableResult
    func write(_ samples: [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        let available = bufferSize - ((writeIndex - readIndex + bufferSize) & bufferMask)
        
        // ----> FIX: More aggressive overflow handling <----
        if samples.count > available {
            // Drop old data to make room for new data
            let samplesToDrop = samples.count - available
            readIndex = (readIndex + samplesToDrop) & bufferMask
            
            overflowCount += 1
            if overflowCount % 100 == 0 {
                print("⚠️ Audio buffer overflow #\(overflowCount), dropped \(samplesToDrop) old samples")
            }
        }
        
        // Write all new samples
        for i in 0..<samples.count {
            buffer[writeIndex & bufferMask] = samples[i]
            writeIndex = (writeIndex + 1) & bufferMask
        }
        
        return samples.count
    }

    func read(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        
        let available = (writeIndex - readIndex + bufferSize) & bufferMask
        let readableCount = min(count, available)
        
        var output = [Float]()
        output.reserveCapacity(readableCount)
        
        for _ in 0..<readableCount {
            output.append(buffer[readIndex & bufferMask])
            readIndex = (readIndex + 1) & bufferMask
        }
        
        return output
    }
    
    // ----> ADD: Reset method <----
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        
        writeIndex = 0
        readIndex = 0
        overflowCount = 0
        
        // Clear the buffer
        for i in 0..<bufferSize {
            buffer[i] = 0.0
        }
        
        print("🔄 Circular buffer reset")
    }
}
