//
//  SocketManager.swift
//  
//
//  Created by Alsey Coleman Miller on 4/1/22.
//

import Foundation
import SystemPackage

/// Socket Manager
internal actor SocketManager {
    
    static let shared = SocketManager()
    
    private var sockets = [FileDescriptor: SocketState]()
    
    private var pollDescriptors = [FileDescriptor.Poll]()
    
    private var isMonitoring = false
        
    private init() { }
    
    private func startMonitoring() {
        guard isMonitoring == false else { return }
        log("Will start monitoring")
        isMonitoring = true
        // Add to runloop of background thread from concurrency thread pool
        Task(priority: Socket.configuration.monitorPriority) { [weak self] in
            while let self = self, isMonitoring {
                do {
                    try await Task.sleep(nanoseconds: Socket.configuration.monitorInterval)
                    try await self.poll()
                    // stop monitoring if no sockets
                    if pollDescriptors.isEmpty {
                        isMonitoring = false
                    }
                }
                catch {
                    log("Socket monitoring failed. \(error.localizedDescription)")
                    assertionFailure("Socket monitoring failed. \(error.localizedDescription)")
                    isMonitoring = false
                }
            }
        }
    }
    
    func contains(_ fileDescriptor: FileDescriptor) -> Bool {
        return sockets.keys.contains(fileDescriptor)
    }
    
    func add(
        fileDescriptor: FileDescriptor,
        event: ((Socket.Event) -> ())? = nil
    ) {
        guard sockets.keys.contains(fileDescriptor) == false else {
            log("Another socket for file descriptor \(fileDescriptor) already exists.")
            assertionFailure("Another socket already exists")
            return
        }
        log("Add socket \(fileDescriptor).")
        // append socket
        sockets[fileDescriptor] = SocketState(
            fileDescriptor: fileDescriptor,
            event: event
        )
        updatePollDescriptors()
        startMonitoring()
    }
    
    func remove(_ fileDescriptor: FileDescriptor, error: Error? = nil) async {
        guard let socket = sockets[fileDescriptor] else {
            return // could have been removed by `poll()`
        }
        log("Remove socket \(fileDescriptor).")
        // update sockets to monitor
        sockets[fileDescriptor] = nil
        updatePollDescriptors()
        // close actual socket
        try? fileDescriptor.close()
        // notify
        await socket.event?(.close(error))
    }
    
    @discardableResult
    internal func write(_ data: Data, for fileDescriptor: FileDescriptor) async throws -> Int {
        guard let socket = sockets[fileDescriptor] else {
            log("Unable to write unkown socket \(fileDescriptor).")
            assertionFailure("Unknown socket \(fileDescriptor)")
            throw Errno.invalidArgument
        }
        let nanoseconds = Socket.configuration.writeInterval
        try await wait(for: .write, fileDescriptor: fileDescriptor, sleep: nanoseconds)
        return try await socket.write(data: data, sleep: nanoseconds)
    }
    
    internal func read(_ length: Int, for fileDescriptor: FileDescriptor) async throws -> Data {
        guard let socket = sockets[fileDescriptor] else {
            log("Unable to read unkown socket \(fileDescriptor).")
            assertionFailure("Unknown socket \(fileDescriptor)")
            throw Errno.invalidArgument
        }
        let nanoseconds = Socket.configuration.readInterval
        try await wait(for: .read, fileDescriptor: fileDescriptor, sleep: nanoseconds)
        return try await socket.read(length: length, sleep: nanoseconds)
    }
    
    internal func setEvent(_ event: ((Socket.Event) -> ())?, for fileDescriptor: FileDescriptor) async throws {
        guard let socket = sockets[fileDescriptor] else {
            log("Unkown socket \(fileDescriptor).")
            assertionFailure("Unknown socket")
            throw Errno.invalidArgument
        }
        await socket.setEvent(event)
    }
    
    internal func event(for fileDescriptor: FileDescriptor) async throws -> ((Socket.Event) -> ())? {
        guard let socket = sockets[fileDescriptor] else {
            log("Unkown socket \(fileDescriptor).")
            assertionFailure("Unknown socket")
            throw Errno.invalidArgument
        }
        return await socket.event
    }
    
    internal func events(for fileDescriptor: FileDescriptor) -> FileEvents {
        guard let poll = pollDescriptors.first(where: { $0.fileDescriptor == fileDescriptor }) else {
            log("Unkown socket \(fileDescriptor).")
            assertionFailure()
            return []
        }
        return poll.returnedEvents
    }
    
    private func wait(
        for event: FileEvents,
        fileDescriptor: FileDescriptor,
        sleep nanoseconds: UInt64 = 10_000_000
    ) async throws {
        repeat {
            try await self.poll()
            try Task.checkCancellation()
            if events(for: fileDescriptor).contains(event) == false {
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        } while events(for: fileDescriptor).contains(event) == false
    }
    
    private func updatePollDescriptors() {
        pollDescriptors = sockets.keys
            .lazy
            .sorted(by: { $0.rawValue < $1.rawValue })
            .map { FileDescriptor.Poll(fileDescriptor: $0, events: .socket) }
    }
    
    internal func poll() async throws {
        pollDescriptors.reset()
        do {
            try pollDescriptors.poll()
        }
        catch {
            log("Unable to poll for events. \(error.localizedDescription)")
            throw error
        }
        
        for poll in pollDescriptors {
            let fileEvents = poll.returnedEvents
            let fileDescriptor = poll.fileDescriptor
            if fileEvents.contains(.read) {
                await shouldRead(fileDescriptor)
            }
            if fileEvents.contains(.invalidRequest) {
                assertionFailure()
                await error(.badFileDescriptor, for: fileDescriptor)
            }
            if fileEvents.contains(.hangup) {
                await error(.connectionReset, for: fileDescriptor)
            }
            if fileEvents.contains(.error) {
                await error(.connectionAbort, for: fileDescriptor)
            }
        }
    }
    
    private func error(_ error: Errno, for fileDescriptor: FileDescriptor) async {
        guard let _ = self.sockets[fileDescriptor] else {
            log("Unkown socket \(fileDescriptor).")
            assertionFailure("Unknown socket")
            return
        }
        await self.remove(fileDescriptor, error: error)
    }
    
    private func shouldRead(_ fileDescriptor: FileDescriptor) async {
        guard let socket = self.sockets[fileDescriptor] else {
            log("Unkown socket \(fileDescriptor).")
            assertionFailure("Unknown socket")
            return
        }
        // notify
        await socket.event?(.pendingRead)
    }
}

// MARK: - Supporting Types

extension SocketManager {
    
    actor SocketState {
        
        let fileDescriptor: FileDescriptor
        
        var event: ((Socket.Event) -> ())?
        
        var isExecuting = false
        
        init(fileDescriptor: FileDescriptor,
             event: ((Socket.Event) -> ())? = nil
        ) {
            self.fileDescriptor = fileDescriptor
            self.event = event
        }
        
        func setEvent(_ newValue: ((Socket.Event) -> ())?) {
            self.event = newValue
        }
    }
}

extension SocketManager.SocketState {
    
    // locks the socket
    private func execute<T>(
        sleep nanoseconds: UInt64 = 10_000_000,
        _ block: () async throws -> (T)
    ) async throws -> T {
        while isExecuting {
            try await Task.sleep(nanoseconds: nanoseconds)
        }
        isExecuting = true
        defer { isExecuting = false }
        return try await block()
    }
    
    func write(data: Data, sleep nanoseconds: UInt64 = 10_000_000) async throws -> Int {
        try await execute(sleep: nanoseconds) {
            log("Will write \(data.count) bytes to \(fileDescriptor)")
            let byteCount = try data.withUnsafeBytes {
                try fileDescriptor.write($0)
            }
            // notify
            event?(.write(byteCount))
            return byteCount
        }
    }
    
    func read(length: Int, sleep nanoseconds: UInt64 = 10_000_000) async throws -> Data {
        try await execute(sleep: nanoseconds) {
            log("Will read \(length) bytes to \(fileDescriptor)")
            var data = Data(count: length)
            let bytesRead = try data.withUnsafeMutableBytes {
                try fileDescriptor.read(into: $0)
            }
            if bytesRead < length {
                data = data.prefix(bytesRead)
            }
            // notify
            event?(.read(bytesRead))
            return data
        }
    }
}
