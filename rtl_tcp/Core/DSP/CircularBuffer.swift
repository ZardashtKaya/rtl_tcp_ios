//
//  Core/DSP/CircularBuffer.swift
//  rtl_tcp
//
//  Created by Zardasht Kaya on 9/4/25.
//

import Foundation

/// A thread-safe circular buffer for audio samples.
class CircularBuffer {
    private var buffer: [Float]
    private var writeIndex = 0
    private var readIndex = 0
    private let bufferSize: Int
    private let lock = NSLock()

    /// The number of samples currently available to be read.
    var availableForReading: Int {
        lock.lock()
        defer { lock.unlock() }
        return (writeIndex - readIndex + bufferSize) % bufferSize
    }

    /// Initializes a new circular buffer.
    /// - Parameter size: The total capacity of the buffer in samples.
    init(size: Int) {
        self.bufferSize = size
        self.buffer = [Float](repeating: 0.0, count: size)
    }

    /// Writes samples to the buffer.
    /// - Parameter samples: An array of floats to write.
    /// - Returns: The number of samples successfully written. Older samples will be overwritten if the buffer is full.
    @discardableResult
    func write(_ samples: [Float]) -> Int {
        lock.lock()
        defer { lock.unlock() }

        for sample in samples {
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % bufferSize
        }
        
        // In a simple implementation, we assume we can always write.
        // A more complex version might handle overwriting the read pointer.
        return samples.count
    }

    /// Reads a specified number of samples from the buffer.
    /// - Parameter count: The maximum number of samples to read.
    /// - Returns: An array of floats containing the read samples. The array may be smaller than `count` if not enough samples are available.
    func read(count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let readableCount = min(count, availableForReading)
        var output = [Float](repeating: 0.0, count: readableCount)

        for i in 0..<readableCount {
            output[i] = buffer[readIndex]
            readIndex = (readIndex + 1) % bufferSize
        }

        return output
    }
}
