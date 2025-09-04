//
//  Core/DSP/CircularBuffer.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation

/// A thread-safe circular buffer for audio samples using standard Swift concurrency.
class CircularBuffer {
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let bufferSize: Int
    private let bufferMask: Int // For fast modulo using bitwise AND
    private let lock = NSLock()

    /// The number of samples currently available to be read.
    var availableForReading: Int {
        lock.lock()
        defer { lock.unlock() }
        return (writeIndex - readIndex + bufferSize) & bufferMask
    }

    /// Initializes a new circular buffer with power-of-2 size for optimal performance.
    /// - Parameter size: The total capacity of the buffer in samples (will be rounded up to next power of 2).
    init(size: Int) {
        // Round up to next power of 2 for efficient modulo operations
        let powerOf2Size = 1 << Int(ceil(log2(Double(size))))
        self.bufferSize = powerOf2Size
        self.bufferMask = powerOf2Size - 1
        self.buffer = [Float](repeating: 0.0, count: powerOf2Size)
    }

    /// Thread-safe write operation.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        for sample in samples {
            buffer[writeIndex & bufferMask] = sample
            writeIndex = (writeIndex + 1) & bufferMask
        }
        
        return samples.count
    }

    /// Thread-safe read operation.
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
}
