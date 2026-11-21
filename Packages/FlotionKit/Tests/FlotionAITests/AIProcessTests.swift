import Foundation
import Testing
@testable import FlotionAI

@Suite(.serialized) struct AIProcessTests {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let workingDirectory = FileManager.default.temporaryDirectory

    @Test func droppingRunningProcessesRemovesTheirReadHandlers() async throws {
        // A readability handler left installed after its AIProcess is freed fires on EOF forever
        // and pegs a core. Drop running processes, including ones that ignore SIGTERM and write
        // output and EOF after the AIProcess is gone, and check no handler is left behind.
        var handles: [FileHandle] = []
        for _ in 0..<4 {
            for script in ["sleep 0.15; echo done", "trap '' TERM; sleep 0.05; echo done"] {
                var process: AIProcess? = try AIProcess(executable: shell, arguments: ["-c", script],
                                                        workingDirectory: workingDirectory, environment: [:])
                weak let dropped = process
                handles.append(try #require(process).outputHandle)
                process = nil
                #expect(dropped == nil)
            }
        }
        // Wait past the children's output and exit.
        try await Task.sleep(for: .milliseconds(300))
        for handle in handles {
            #expect(handle.readabilityHandler == nil)
        }
    }

    @Test func endOfOutputRemovesTheReadHandler() async throws {
        let process = try AIProcess(executable: shell, arguments: ["-c", "echo one"],
                                    workingDirectory: workingDirectory, environment: [:])
        let handle = process.outputHandle
        var received = 0
        for await _ in process.lines() { received += 1 }
        #expect(received == 1)
        #expect(handle.readabilityHandler == nil)
    }

    @Test func normalEOFDeliversAllLinesIncludingTrailingLineWithoutNewline() async throws {
        let process = try AIProcess(
            executable: shell,
            arguments: ["-c", "printf 'first\\nsecond\\n\\nlast-without-newline'"],
            workingDirectory: workingDirectory,
            environment: [:]
        )
        var received: [String] = []
        for await line in process.lines() {
            received.append(String(decoding: line, as: UTF8.self))
        }
        #expect(received == ["first", "second", "last-without-newline"])
    }

    @Test func earlyEOFBeforeAttachReplaysBacklogIncludingTrailingLine() async throws {
        let process = try AIProcess(
            executable: shell,
            arguments: ["-c", "printf 'alpha\\nbeta'"],
            workingDirectory: workingDirectory,
            environment: [:]
        )
        // Give the child time to emit stdout and close the pipe before attaching.
        try await Task.sleep(for: .milliseconds(100))
        var received: [String] = []
        for await line in process.lines() {
            received.append(String(decoding: line, as: UTF8.self))
        }
        #expect(received == ["alpha", "beta"])
    }

    @Test func largeStdinWriteDoesNotBlockCallerAndPreservesOrder() async throws {
        // Child sleeps 150ms before reading stdin so any synchronous write exceeding macOS's
        // 16 KB pipe buffer would block the caller for ~150ms.
        let process = try AIProcess(
            executable: shell,
            arguments: ["-c", "sleep 0.15; cat"],
            workingDirectory: workingDirectory,
            environment: [:]
        )
        let lines = process.lines()

        let chunkA = "START:" + String(repeating: "A", count: 48 * 1024) + ":MID\n"
        let chunkB = "NEXT:" + String(repeating: "B", count: 48 * 1024) + ":END\n"

        let clock = ContinuousClock()
        let writeDuration = clock.measure {
            process.send(Data(chunkA.utf8))
            process.send(Data(chunkB.utf8))
            process.closeInput()
        }

        #expect(writeDuration < .milliseconds(100), "send/closeInput should not block on pipe backpressure (took \(writeDuration))")

        var received: [String] = []
        for await line in lines {
            received.append(String(decoding: line, as: UTF8.self))
        }
        #expect(received == [String(chunkA.dropLast()), String(chunkB.dropLast())])
    }

    @Test func launchFailureDoesNotLeakOrCrash() {
        #expect(throws: Error.self) {
            _ = try AIProcess(
                executable: URL(fileURLWithPath: "/nonexistent/flotion-missing-binary"),
                arguments: [],
                workingDirectory: workingDirectory,
                environment: [:]
            )
        }
    }

    @Test func terminateIsIdempotentAndFinishesStream() async throws {
        let process = try AIProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectory: workingDirectory,
            environment: [:]
        )
        let lines = process.lines()
        let reader = Task<[Data], Never> {
            var collected: [Data] = []
            for await line in lines {
                collected.append(line)
            }
            return collected
        }
        try await Task.sleep(for: .milliseconds(30))
        process.terminate()
        process.terminate()
        let collected = await reader.value
        #expect(collected.isEmpty)
    }

    @Test func terminatingDuringBlockedLargeStdinWriteDoesNotHangOrCrash() async throws {
        let process = try AIProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            workingDirectory: workingDirectory,
            environment: [:]
        )
        process.send(Data(repeating: 0x41, count: 128 * 1024))
        try await Task.sleep(for: .milliseconds(20))

        let clock = ContinuousClock()
        let terminateDuration = clock.measure {
            process.terminate()
        }
        #expect(terminateDuration < .milliseconds(500))
        // The queued write sees EPIPE once the child is gone, without raising SIGPIPE.
        #expect(process.waitForInputIdle(timeout: .seconds(2)))
    }

    @Test func terminateStopsAWriteTheChildNeverReads() async throws {
        // The child ignores SIGTERM and never reads stdin, so the pipe stays full until it exits.
        let process = try AIProcess(executable: shell, arguments: ["-c", "trap '' TERM; sleep 2"],
                                    workingDirectory: workingDirectory, environment: [:])
        process.send(Data(repeating: 0x41, count: 128 * 1024))
        process.closeInput()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!process.waitForInputIdle(timeout: .milliseconds(1)), "the write should still be waiting on the full pipe")

        process.terminate()
        // Well before the child exits at 2 s, the write gives up and stdin is closed.
        #expect(process.waitForInputIdle(timeout: .milliseconds(800)))
    }
}
