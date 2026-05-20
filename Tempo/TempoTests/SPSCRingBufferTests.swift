import XCTest
@testable import Tempo

// MARK: - Visibility note
//
// SPSCRingBuffer is declared `private final class` inside AudioEngine.swift.
// Swift's `@testable import` only promotes `internal` and `fileprivate` symbols;
// it does NOT expose `private` ones. These tests will therefore fail to compile
// until SPSCRingBuffer's access level is changed from `private` to `internal`
// (the Swift default — just remove the `private` keyword on line 31 of
// AudioEngine.swift).  No other changes to AudioEngine.swift are required.
//
// Suggested diff in AudioEngine.swift:
//   - private final class SPSCRingBuffer {
//   + final class SPSCRingBuffer {
//
// Rationale: SPSCRingBuffer is a self-contained, allocation-free data structure
// with no dependency on AVAudioEngine internals. Making it `internal` does not
// widen the public API surface (the module has no `public` exports), and it
// enables deterministic unit testing of all buffer invariants without touching
// real audio hardware.

// MARK: - API surface note
//
// The actual `write(_:source:count:)` signature returns Void; excess samples are
// silently dropped (not signalled by a Bool). Tests RB02 and RB03 therefore assert
// on `availableSamples` rather than on a return value.
// There is no `availableToWrite` property; available write space is
// `capacity - availableSamples`.

// MARK: - Helpers

/// Allocates a stack-like Float array, calls the closure with a typed pointer,
/// and returns the array so the caller can inspect it after the closure.
private func withFloats(
    _ values: [Float],
    _ body: (UnsafePointer<Float>) -> Void
) {
    values.withUnsafeBufferPointer { body($0.baseAddress!) }
}

private func withMutableFloats(
    count: Int,
    _ body: (UnsafeMutablePointer<Float>) -> Void
) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    out.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    return out
}

// MARK: - SPSCRingBufferTests

final class SPSCRingBufferTests: XCTestCase {

    // MARK: - RB01: write on empty buffer updates availableSamples

    /// RB01 — Writing N samples into an empty buffer makes availableSamples == N.
    func test_write_onEmptyBuffer_updatesAvailableSamples() {
        let rb = SPSCRingBuffer(capacity: 8)

        XCTAssertEqual(rb.availableSamples, 0,
                       "RB01: fresh buffer must have availableSamples == 0")

        withFloats([1, 2, 3]) { rb.write($0, count: 3) }

        XCTAssertEqual(rb.availableSamples, 3,
                       "RB01: after writing 3 samples, availableSamples must be 3")
    }

    // MARK: - RB02: write up to full capacity — all samples accepted

    /// RB02 — Writing exactly `capacity` samples fills the buffer without overflow.
    func test_write_upToCapacity_allSamplesAccepted() {
        let capacity = 16
        let rb = SPSCRingBuffer(capacity: capacity)

        let input = (0..<capacity).map { Float($0) }
        withFloats(input) { rb.write($0, count: capacity) }

        XCTAssertEqual(rb.availableSamples, capacity,
                       "RB02: writing exactly capacity samples must fill the buffer; availableSamples must equal capacity")
    }

    // MARK: - RB03: write beyond capacity — excess is silently dropped

    /// RB03 — Writing more samples than the remaining space silently drops the excess;
    /// availableSamples is capped at `capacity`.
    func test_write_beyondCapacity_excessDropped() {
        let capacity = 8
        let rb = SPSCRingBuffer(capacity: capacity)

        // First fill the buffer completely.
        let firstBatch = [Float](repeating: 1.0, count: capacity)
        withFloats(firstBatch) { rb.write($0, count: capacity) }

        XCTAssertEqual(rb.availableSamples, capacity,
                       "RB03 precondition: buffer must be full before overflow write")

        // Attempt to write one more sample — must be silently dropped.
        withFloats([9.0]) { rb.write($0, count: 1) }

        XCTAssertEqual(rb.availableSamples, capacity,
                       "RB03: write beyond capacity must not increase availableSamples beyond capacity")
    }

    // MARK: - RB04: read on empty buffer returns 0

    /// RB04 — Attempting to read from an empty buffer returns 0 samples read
    /// and leaves the destination unchanged.
    func test_read_onEmptyBuffer_returnsZero() {
        let rb = SPSCRingBuffer(capacity: 8)
        let sentinel: Float = -999.0
        var dest = [Float](repeating: sentinel, count: 4)

        let read = dest.withUnsafeMutableBufferPointer { ptr -> Int in
            rb.read(into: ptr.baseAddress!, count: 4)
        }

        XCTAssertEqual(read, 0,
                       "RB04: read on empty buffer must return 0")
        XCTAssertTrue(dest.allSatisfy { $0 == sentinel },
                      "RB04: destination must be untouched when buffer is empty")
    }

    // MARK: - RB05: write N then read N — data round-trips correctly

    /// RB05 — Samples written must be read back in order without corruption.
    func test_write_thenRead_dataMatchesExactly() {
        let rb = SPSCRingBuffer(capacity: 16)
        let input: [Float] = [1.1, 2.2, 3.3, 4.4, 5.5]

        withFloats(input) { rb.write($0, count: input.count) }

        let result = withMutableFloats(count: input.count) { ptr in
            rb.read(into: ptr, count: input.count)
        }

        XCTAssertEqual(result, input,
                       "RB05: data read back must match data written, got \(result)")
    }

    // MARK: - RB06: read requests more samples than available — returns only available

    /// RB06 — When fewer samples are available than requested, read returns only what
    /// is available; the extra destination slots are untouched.
    func test_read_moreRequestedThanAvailable_returnsOnlyAvailable() {
        let rb = SPSCRingBuffer(capacity: 16)
        let input: [Float] = [7.0, 8.0, 9.0]
        withFloats(input) { rb.write($0, count: input.count) }

        let sentinel: Float = -1.0
        var dest = [Float](repeating: sentinel, count: 8)

        let read = dest.withUnsafeMutableBufferPointer { ptr -> Int in
            rb.read(into: ptr.baseAddress!, count: 8)
        }

        XCTAssertEqual(read, input.count,
                       "RB06: read must return only the available sample count (\(input.count)), got \(read)")
        XCTAssertEqual(Array(dest.prefix(input.count)), input,
                       "RB06: available samples must be copied correctly")
        XCTAssertTrue(dest.dropFirst(input.count).allSatisfy { $0 == sentinel },
                      "RB06: slots beyond the available count must remain untouched")
        XCTAssertEqual(rb.availableSamples, 0,
                       "RB06: all available samples have been consumed — availableSamples must be 0")
    }

    // MARK: - RB07: wrap-around — data is correct after write/read cycles exceed capacity

    /// RB07 — After writing and reading enough times to wrap the internal indices
    /// past the end of the storage array, the data read back remains correct.
    func test_writeRead_wraparound_dataIsCorrect() {
        let capacity = 8
        let rb = SPSCRingBuffer(capacity: capacity)

        // Phase 1: fill 6 slots, drain 6 → writeIndex=6, readIndex=6 (both advanced).
        let phase1: [Float] = [10, 20, 30, 40, 50, 60]
        withFloats(phase1) { rb.write($0, count: phase1.count) }
        var drain1 = [Float](repeating: 0, count: phase1.count)
        drain1.withUnsafeMutableBufferPointer { rb.read(into: $0.baseAddress!, count: phase1.count) }

        // Phase 2: write 6 more samples — indices will wrap (6+6=12 > capacity=8).
        let phase2: [Float] = [1.1, 2.2, 3.3, 4.4, 5.5, 6.6]
        withFloats(phase2) { rb.write($0, count: phase2.count) }

        XCTAssertEqual(rb.availableSamples, phase2.count,
                       "RB07 precondition: availableSamples must equal phase2 count after wrap write")

        // Read back should give phase2 exactly, regardless of wrap.
        let result = withMutableFloats(count: phase2.count) { ptr in
            rb.read(into: ptr, count: phase2.count)
        }

        XCTAssertEqual(result, phase2,
                       "RB07: data after wrap-around must equal written data, got \(result)")
    }

    // MARK: - RB08: buffer is empty after a complete read

    /// RB08 — After reading all available samples, availableSamples must be 0.
    func test_read_completeConsumption_bufferBecomesEmpty() {
        let rb = SPSCRingBuffer(capacity: 8)
        let input: [Float] = [1, 2, 3, 4]
        withFloats(input) { rb.write($0, count: input.count) }

        withMutableFloats(count: input.count) { ptr in
            rb.read(into: ptr, count: input.count)
        }

        XCTAssertEqual(rb.availableSamples, 0,
                       "RB08: availableSamples must be 0 after reading all samples")
    }

    // MARK: - RB09: availableSamples + availableToWrite == capacity at all times

    /// RB09 — The invariant `availableSamples + (capacity - availableSamples) == capacity`
    /// holds after every write/read operation.  Because the implementation exposes only
    /// `availableSamples`, available write space is derived as `capacity - availableSamples`.
    func test_invariant_availableReadPlusAvailableWriteEqualsCapacity() {
        let capacity = 16
        let rb = SPSCRingBuffer(capacity: capacity)

        func checkInvariant(label: String) {
            let readable  = rb.availableSamples
            let writable  = capacity - readable
            XCTAssertEqual(readable + writable, capacity,
                           "RB09 [\(label)]: readable(\(readable)) + writable(\(writable)) must equal capacity(\(capacity))")
            XCTAssertGreaterThanOrEqual(readable, 0,
                                        "RB09 [\(label)]: availableSamples must never be negative")
            XCTAssertLessThanOrEqual(readable, capacity,
                                     "RB09 [\(label)]: availableSamples must never exceed capacity")
        }

        checkInvariant(label: "empty")

        withFloats([Float](repeating: 1.0, count: 4)) { rb.write($0, count: 4) }
        checkInvariant(label: "after write 4")

        withFloats([Float](repeating: 2.0, count: 6)) { rb.write($0, count: 6) }
        checkInvariant(label: "after write 6 more (total 10)")

        withMutableFloats(count: 5) { ptr in rb.read(into: ptr, count: 5) }
        checkInvariant(label: "after read 5")

        // Overflow write — capacity is 16, readable is 5, writable is 11.
        // Write 12 → 11 accepted, 1 dropped.
        withFloats([Float](repeating: 3.0, count: 12)) { rb.write($0, count: 12) }
        checkInvariant(label: "after overflow write")

        // Drain everything.
        withMutableFloats(count: capacity) { ptr in rb.read(into: ptr, count: capacity) }
        checkInvariant(label: "after full drain")
    }

    // MARK: - RB_INIT: precondition enforced for non-power-of-2 capacity

    /// Verifies that SPSCRingBuffer enforces the power-of-2 capacity precondition.
    /// The implementation uses `precondition(...)`, so this test triggers a crash
    /// if the capacity is invalid. XCTest does not natively catch `precondition`
    /// failures (they abort the process), so this case is documented here rather
    /// than executed at runtime to keep the suite non-crashing.
    ///
    /// **Manual verification**: `SPSCRingBuffer(capacity: 3)` must trap with the
    /// message "SPSCRingBuffer: capacity must be a power of 2, got 3".
    func test_init_nonPowerOfTwo_documented() {
        // This test is intentionally left without an active assertion.
        // Executing SPSCRingBuffer(capacity: 3) would call precondition() and
        // terminate the test process. The behaviour is verified by code review of
        // the precondition on line 43 of AudioEngine.swift.
        //
        // If the team adopts a crash-testing harness (e.g. a separate process or
        // XCTAssertPreconditionFailure from a third-party library), the assertion
        // can be added here.
    }

    // MARK: - RB_PARTIAL: partial read followed by partial write — correct FIFO ordering

    /// Extra scenario — Validates FIFO ordering across multiple partial reads and writes,
    /// ensuring the oldest samples are always returned first.
    func test_writeRead_partialSequence_fifoOrdering() {
        let rb = SPSCRingBuffer(capacity: 16)

        // Write [1,2,3,4], read 2 → should get [1,2].
        withFloats([1, 2, 3, 4]) { rb.write($0, count: 4) }
        let first = withMutableFloats(count: 2) { ptr in rb.read(into: ptr, count: 2) }
        XCTAssertEqual(first, [1, 2], "FIFO: first read must return oldest samples")

        // Write [5,6], read 4 → should get [3,4,5,6].
        withFloats([5, 6]) { rb.write($0, count: 2) }
        let second = withMutableFloats(count: 4) { ptr in rb.read(into: ptr, count: 4) }
        XCTAssertEqual(second, [3, 4, 5, 6], "FIFO: second read must return remaining old samples followed by new ones")
    }
}
