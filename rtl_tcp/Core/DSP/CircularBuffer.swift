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
    
    // ----> ADD: Overflow protection <----
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
        
        // ----> FIX: Prevent buffer overflow <----
        let available = bufferSize - ((writeIndex - readIndex + bufferSize) & bufferMask)
        if samples.count > available {
            overflowCount += 1
            if overflowCount % 50 == 0 {
                print("⚠️ Audio buffer overflow #\(overflowCount), dropping \(samples.count - available) samples")
            }
            
            // Skip samples if we're overflowing too much
            if overflowCount > maxOverflows {
                readIndex = (readIndex + samples.count) & bufferMask
                overflowCount = 0
            }
        }
        
        let samplesToWrite = min(samples.count, available)
        for i in 0..<samplesToWrite {
            buffer[writeIndex & bufferMask] = samples[i]
            writeIndex = (writeIndex + 1) & bufferMask
        }
        
        return samplesToWrite
    }

    func read(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        
        let available = (writeIndex - readIndex + bufferSize) & bufferMask
        let readableCount = min(count, available)
        
        // ----> FIX: Pre-allocate output array <----
        var output = [Float]()
        output.reserveCapacity(readableCount)
        
        for _ in 0..<readableCount {
            output.append(buffer[readIndex & bufferMask])
            readIndex = (readIndex + 1) & bufferMask
        }
        
        return output
    }
    
    // ----> ADD: Cleanup method <----
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        writeIndex = 0
        readIndex = 0
        overflowCount = 0
    }
}
