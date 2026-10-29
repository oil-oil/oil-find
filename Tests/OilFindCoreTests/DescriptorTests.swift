import COilFind
import Darwin
import XCTest

final class DescriptorTests: XCTestCase {
    private func makeSocketPair() throws -> (Int32, Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, buffer.baseAddress!)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (descriptors[0], descriptors[1])
    }

    private func makeSourceFile(contents: Data) throws -> (URL, Int32) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("OilFindDescriptor-" + UUID().uuidString)
        try contents.write(to: url)
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY) }
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: url)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return (url, descriptor)
    }

    private func readContents(_ descriptor: Int32, count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress, buffer.count, 0)
        }
        guard readCount >= 0 else { return Data() }
        return Data(bytes.prefix(Int(readCount)))
    }

    private func waitUntilReadable(_ descriptor: Int32) -> Bool {
        var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = withUnsafeMutablePointer(to: &state) {
            Darwin.poll($0, nfds_t(1), 1_000)
        }
        return result > 0 && state.revents & Int16(POLLIN) != 0
    }

    func testSendAndReceiveTransfersDescriptorAndSetsCloseOnExec() throws {
        let payload = Data("descriptor transfer payload".utf8)
        let (url, source) = try makeSourceFile(contents: payload)
        defer {
            _ = Darwin.close(source)
            try? FileManager.default.removeItem(at: url)
        }
        let (sender, receiver) = try makeSocketPair()
        defer {
            _ = Darwin.close(sender)
            _ = Darwin.close(receiver)
        }

        XCTAssertEqual(sift_send_fd(sender, source), 0)
        XCTAssertTrue(waitUntilReadable(receiver), "sent descriptor datagram should become readable")
        let transferred = sift_receive_fd(receiver)
        XCTAssertGreaterThanOrEqual(transferred, 0)
        guard transferred >= 0 else { return }
        defer { _ = Darwin.close(transferred) }

        XCTAssertEqual(readContents(transferred, count: payload.count), payload)
        XCTAssertEqual(readContents(source, count: payload.count), payload, "sending must leave the source descriptor usable")
        let flags = Darwin.fcntl(transferred, F_GETFD)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
    }

    func testSendToClosedPeerReturnsErrorWithoutSIGPIPE() throws {
        let (url, source) = try makeSourceFile(contents: Data("x".utf8))
        defer {
            _ = Darwin.close(source)
            try? FileManager.default.removeItem(at: url)
        }
        let (sender, receiver) = try makeSocketPair()
        _ = Darwin.close(receiver)
        defer { _ = Darwin.close(sender) }

        errno = 0
        XCTAssertEqual(sift_send_fd(sender, source), -1)
        XCTAssertNotEqual(errno, 0)
    }

    func testMalformedDatagramIsRejectedBeforeFollowingValidPacket() throws {
        let payload = Data("next packet".utf8)
        let (url, source) = try makeSourceFile(contents: payload)
        defer {
            _ = Darwin.close(source)
            try? FileManager.default.removeItem(at: url)
        }
        let (sender, receiver) = try makeSocketPair()
        defer {
            _ = Darwin.close(sender)
            _ = Darwin.close(receiver)
        }

        var invalidMarker: UInt8 = 0
        let malformedCount = withUnsafePointer(to: &invalidMarker) {
            Darwin.send(sender, $0, MemoryLayout<UInt8>.size, 0)
        }
        XCTAssertEqual(malformedCount, 1)
        XCTAssertTrue(waitUntilReadable(receiver), "malformed datagram should become readable")
        errno = 0
        XCTAssertEqual(sift_receive_fd(receiver), -1)
        XCTAssertEqual(errno, EPROTO)

        XCTAssertEqual(sift_send_fd(sender, source), 0)
        XCTAssertTrue(waitUntilReadable(receiver), "valid datagram after rejection should remain readable")
        let transferred = sift_receive_fd(receiver)
        XCTAssertGreaterThanOrEqual(transferred, 0)
        guard transferred >= 0 else { return }
        defer { _ = Darwin.close(transferred) }
        XCTAssertEqual(readContents(transferred, count: payload.count), payload)
    }
}
