import Foundation
import NIOCore
import NIOSSH
import os

/// Configuration for one herdr bridge: which remote socket to reach and how to
/// reach it. The command builders are DATA (spec §3/Track U) so the fallback
/// tree (herdr api proxy → socat → python pump) can change without logic
/// changes. Defaults verified against herdr v0.7.3 + socat 1.8 on Ubuntu 24.04.
struct HerdrBridgeConfig: Sendable {
    /// Remote path to herdr's API socket. Expanded by the REMOTE shell — the
    /// default deliberately uses ${XDG_CONFIG_HOME:-...} because
    /// HERDR_SOCKET_PATH is not reliably present in a non-login exec shell.
    var socketPath: String
    /// Reconnect attempts before the bridge surfaces `.disconnected`.
    var maxAttempts: Int
    var initialBackoff: TimeAmount
    var maxBackoff: TimeAmount
    /// Events-pipe command: a plain socat — the pipe sends exactly one
    /// events.subscribe line and then only reads (0.7.3 semantics).
    var eventsCommand: @Sendable (String) -> String
    /// Requests-pipe command: a while-read loop opening a FRESH one-shot server
    /// connection per request line (0.7.3 closes request connections after the
    /// response), multiplexed over this one persistent SSH exec channel.
    var requestsCommand: @Sendable (String) -> String

    static let defaultSocketPath = "${XDG_CONFIG_HOME:-$HOME/.config}/herdr/herdr.sock"

    init(
        socketPath: String = HerdrBridgeConfig.defaultSocketPath,
        maxAttempts: Int = 10,
        initialBackoff: TimeAmount = .milliseconds(500),
        maxBackoff: TimeAmount = .seconds(30),
        eventsCommand: @escaping @Sendable (String) -> String = { path in
            // `exec` replaces the remote shell so its lifecycle IS socat's.
            "exec socat STDIO UNIX-CONNECT:\"\(path)\""
        },
        requestsCommand: @escaping @Sendable (String) -> String = { path in
            "while IFS= read -r line; do printf '%s\\n' \"$line\" | socat - UNIX-CONNECT:\"\(path)\"; done"
        }
    ) {
        self.socketPath = socketPath
        self.maxAttempts = maxAttempts
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.eventsCommand = eventsCommand
        self.requestsCommand = requestsCommand
    }
}

/// The NIO side of the herdr bridge (spec §5.4): TWO SSH exec child channels on
/// the authenticated parent, glued into one `HerdrTransport` for the client.
///
///   * requests pipe — exec channel running the remote pump loop; every NDJSON
///     line the client writes gets its own one-shot server connection, and the
///     single response line comes back on this channel.
///   * events pipe — exec channel running plain socat; the client writes one
///     events.subscribe line, then herdr streams events until the drop.
///
/// Init follows PortForwardManager's shape (authenticated parent Channel +
/// single-threaded EventLoopGroup + config + state callback) and its THREADING
/// INVARIANT: all mutable state is touched only on `loop` (`numberOfThreads ==
/// 1`), so no locks are needed; the class is Sendable by confinement.
///
/// Framing note: the pure `NDJSONLineFramer` is fed directly from each pipe's
/// `ExecChannelHandler` output callback — no NIO ByteToMessageDecoder adapter
/// is needed, which keeps framing fully in the hermetic test target's reach.
///
/// Teardown: closes the two child channels; the parent connection and the PTY
/// shell channel are never touched (spec §2: the terminal must keep working
/// even if the bridge never comes up).
final class HerdrBridgeChannel: HerdrTransport, @unchecked Sendable {
    private let parentChannel: Channel
    private let group: EventLoopGroup
    private let config: HerdrBridgeConfig
    /// State callback on the transport lifecycle. Invoked on the event loop;
    /// consumers that drive UI must hop to the main actor themselves.
    private let onState: (HerdrTransportState) -> Void

    private var loop: EventLoop { group.next() }

    // MARK: Loop-confined state (event loop only — see invariant above)

    private var children: [HerdrPipe: Channel] = [:]
    private var framers: [HerdrPipe: NDJSONLineFramer] = [:]
    /// Single-flight guard: never two concurrent bridge opens (spec §3).
    private var opening = false
    private var deliberateClose = false
    private var attempt = 0
    private var scheduledRetry: Scheduled<Void>?
    private var pendingConnects: [CheckedContinuation<Void, Error>] = []
    private var eventsRestart: CheckedContinuation<Void, Error>?

    private let inboundContinuation: AsyncStream<Data>.Continuation
    private let inboundStream: AsyncStream<Data>
    private let stateContinuation: AsyncStream<HerdrTransportState>.Continuation
    private let stateStream: AsyncStream<HerdrTransportState>

    private let log = Logger(subsystem: "io.github.madeye.gterm", category: "HerdrBridge")

    init(
        parentChannel: Channel,
        group: EventLoopGroup,
        config: HerdrBridgeConfig,
        onState: @escaping (HerdrTransportState) -> Void = { _ in }
    ) {
        self.parentChannel = parentChannel
        self.group = group
        self.config = config
        self.onState = onState
        (inboundStream, inboundContinuation) = AsyncStream.makeStream()
        (stateStream, stateContinuation) = AsyncStream.makeStream()
    }

    // MARK: HerdrTransport

    var inbound: AsyncStream<Data> { inboundStream }
    var stateChanges: AsyncStream<HerdrTransportState> { stateStream }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loop.execute {
                if self.children.count == 2 {
                    cont.resume()
                    return
                }
                self.pendingConnects.append(cont)
                self.openBoth()
            }
        }
    }

    func send(_ data: Data, to pipe: HerdrPipe) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loop.execute {
                guard let child = self.children[pipe], child.isActive else {
                    cont.resume(throwing: HerdrError.disconnected)
                    return
                }
                var buf = child.allocator.buffer(capacity: data.count + 1)
                buf.writeBytes(NDJSONLineEncoder.encode(data))
                child.writeAndFlush(buf).whenComplete { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let error): cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    func restartEvents() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loop.execute {
                guard !self.deliberateClose else {
                    cont.resume(throwing: HerdrError.disconnected)
                    return
                }
                guard self.eventsRestart == nil else {
                    cont.resume(throwing: HerdrError.bridgeUnavailable("events restart in flight"))
                    return
                }
                self.eventsRestart = cont
                if let events = self.children[.events] {
                    // The close fires pipeExited(.events), which reopens the pipe.
                    events.close(promise: nil)
                } else {
                    self.openEventsPipe()
                }
            }
        }
    }

    func disconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            loop.execute {
                self.deliberateClose = true
                self.scheduledRetry?.cancel()
                self.scheduledRetry = nil
                for child in self.children.values { child.close(promise: nil) }
                self.children.removeAll()
                self.failPendingConnects(HerdrError.disconnected)
                if let restart = self.eventsRestart {
                    self.eventsRestart = nil
                    restart.resume(throwing: HerdrError.disconnected)
                }
                self.emit(.disconnected)
                self.inboundContinuation.finish()
                self.stateContinuation.finish()
                cont.resume()
            }
        }
    }

    // MARK: Open / reconnect (event loop only)

    private func openBoth() {
        guard !opening, !deliberateClose, children.isEmpty else { return }
        opening = true
        openPipe(.requests)
            .flatMap { [weak self] requests -> EventLoopFuture<Channel> in
                guard let self else {
                    return requests.eventLoop.makeFailedFuture(HerdrError.disconnected)
                }
                self.children[.requests] = requests
                return self.openPipe(.events)
            }
            .whenComplete { [weak self] result in
                guard let self else { return }
                self.opening = false
                switch result {
                case .success(let events):
                    self.children[.events] = events
                    self.attempt = 0
                    self.log.info("bridge open (requests + events pipes)")
                    let pending = self.pendingConnects
                    self.pendingConnects.removeAll()
                    pending.forEach { $0.resume() }
                    self.emit(.connected)
                case .failure(let error):
                    self.log.notice("bridge open failed: \(String(describing: error), privacy: .public)")
                    // Tear down the half-open pair before retrying.
                    self.children.values.forEach { $0.close(promise: nil) }
                    self.children.removeAll()
                    self.scheduleReconnect()
                }
            }
    }

    private func openPipe(_ pipe: HerdrPipe) -> EventLoopFuture<Channel> {
        let command = pipe == .requests
            ? config.requestsCommand(config.socketPath)
            : config.eventsCommand(config.socketPath)
        let loop = self.loop
        return parentChannel.pipeline.handler(type: NIOSSHHandler.self).flatMap { sshHandler in
            let promise = loop.makePromise(of: Channel.self)
            sshHandler.createChannel(promise, channelType: .session) { [weak self] child, _ in
                guard let self else {
                    return child.eventLoop.makeFailedFuture(HerdrError.disconnected)
                }
                let handler = ExecChannelHandler(
                    command: command,
                    onOutput: { [weak self] buf in self?.consumeOutput(buf, pipe: pipe) },
                    onExit: { [weak self] exit in self?.pipeExited(pipe, exit) }
                )
                return child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                    .flatMap { child.pipeline.addHandler(handler) }
            }
            return promise.futureResult
        }
    }

    private func openEventsPipe() {
        openPipe(.events).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let channel):
                self.children[.events] = channel
                if let restart = self.eventsRestart {
                    self.eventsRestart = nil
                    restart.resume()
                }
            case .failure(let error):
                if let restart = self.eventsRestart {
                    self.eventsRestart = nil
                    restart.resume(throwing: error)
                }
                self.pipeDropped()
            }
        }
    }

    // MARK: Inbound bytes → NDJSON lines (event loop only)

    private func consumeOutput(_ buf: ByteBuffer, pipe: HerdrPipe) {
        var framer = framers[pipe] ?? NDJSONLineFramer()
        do {
            let lines = try framer.feed(buf.readableBytesView)
            framers[pipe] = framer
            for line in lines {
                inboundContinuation.yield(line)
            }
        } catch {
            // Oversized line = connection error (spec §5.2): drop the pipe, the
            // reconnect policy takes over. Never log the bytes themselves.
            log.error("framing violation on \(pipe == .requests ? "requests" : "events", privacy: .public) pipe — closing")
            framers[pipe] = NDJSONLineFramer()
            children[pipe]?.close(promise: nil)
        }
    }

    // MARK: Drop handling (event loop only)

    /// Called exactly once per pipe incarnation by ExecChannelHandler's onExit.
    private func pipeExited(_ pipe: HerdrPipe, _ exit: ExecChannelExit) {
        children[pipe] = nil
        framers[pipe] = NDJSONLineFramer()
        switch exit {
        case .status(let code) where code != 0:
            log.notice("\(pipe == .requests ? "requests" : "events", privacy: .public) pipe exited status \(code, privacy: .public)")
        case .signal(let name):
            log.notice("pipe killed by signal \(name, privacy: .public)")
        default:
            break
        }

        if deliberateClose { return }

        // An events-pipe restart is an expected close — reopen, don't reconnect.
        if pipe == .events, eventsRestart != nil {
            openEventsPipe()
            return
        }
        // exit 127: bridge tool missing on the host — retrying won't help
        // (Phase 4.2 turns this into the "bridge tool missing" remediation).
        if exit.isCommandNotFound {
            log.error("bridge tool missing on host (exit 127) — giving up")
            giveUp()
            return
        }
        // Paired lifecycle: a drop on either pipe restarts the whole bridge —
        // after every reconnect the client re-gates and re-subscribes anyway.
        children.values.forEach { $0.close(promise: nil) }
        children.removeAll()
        pipeDropped()
    }

    private func pipeDropped() {
        guard !deliberateClose else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !deliberateClose, scheduledRetry == nil else { return }
        attempt += 1
        guard attempt <= config.maxAttempts else {
            giveUp()
            return
        }
        let delay = backoffDelay(attempt: attempt)
        log.info("reconnecting bridge in \(Double(delay.nanoseconds) / 1e9, privacy: .public)s (attempt \(self.attempt, privacy: .public)/\(self.config.maxAttempts, privacy: .public))")
        emit(.retrying)
        scheduledRetry = loop.scheduleTask(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.scheduledRetry = nil
            self.openBoth()
        }
    }

    private func giveUp() {
        log.error("bridge giving up — surfacing disconnected")
        failPendingConnects(HerdrError.bridgeUnavailable("open failed"))
        emit(.disconnected)
    }

    private func backoffDelay(attempt: Int) -> TimeAmount {
        let base = Double(config.initialBackoff.nanoseconds)
        let capped = min(base * pow(2.0, Double(attempt - 1)), Double(config.maxBackoff.nanoseconds))
        // ±25% jitter so a fleet of reconnecting clients doesn't herd (pun intended).
        let jitter = Double.random(in: 0...(capped * 0.25))
        return .nanoseconds(Int64(capped + jitter))
    }

    private func emit(_ state: HerdrTransportState) {
        onState(state)
        stateContinuation.yield(state)
    }

    private func failPendingConnects(_ error: Error) {
        let pending = pendingConnects
        pendingConnects.removeAll()
        pending.forEach { $0.resume(throwing: error) }
    }
}
