import NIOCore
import NIOSSH

/// Terminal condition of an exec'd remote command.
enum ExecChannelExit: Equatable {
    /// Server sent exit-status. 127 carries the conventional "command not
    /// found" meaning — the herdr bridge's fallback probing keys off it.
    case status(Int)
    /// Command died on a signal (name without "SIG", e.g. "KILL").
    case signal(String)
    /// Channel closed without an exit-status (drop, kill -9 of the channel,
    /// server reboot). Distinct from a reported status so the bridge can
    /// treat it as "transport lost" rather than "command failed".
    case closed

    var isCommandNotFound: Bool {
        self == .status(127)
    }
}

/// Handles a single SSH "session" child channel running ONE command via an
/// exec request — no PTY. Modeled on `PTYChannelHandler` but for byte pipes:
///   * inbound  SSHChannelData (server stdout/stderr) -> onOutput
///   * outbound bytes                                   -> SSHChannelData (write)
/// Remote exit-status / exit-signal arrive as user inbound events on the child
/// channel and are surfaced via `onExit`. Half-close is honored: the channel is
/// configured with allowRemoteHalfClosure, and an input-closed event is
/// forwarded so downstream (framing/bridge) sees EOF before the full close.
final class ExecChannelHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = Never
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    private let command: String
    /// Bytes from the server. Invoked on the channel's event loop.
    private let onOutput: (ByteBuffer) -> Void
    /// Terminal condition, delivered exactly once (first of status/signal/close).
    private let onExit: (ExecChannelExit) -> Void

    /// Guards the "exactly once" delivery of onExit — a command that exits
    /// normally also closes the channel, and only the first signal is meaningful.
    private var exitDelivered = false

    init(
        command: String,
        onOutput: @escaping (ByteBuffer) -> Void,
        onExit: @escaping (ExecChannelExit) -> Void
    ) {
        self.command = command
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func channelActive(context: ChannelHandlerContext) {
        // wantReply so a rejected exec (e.g. shell refuses the command) fails
        // the channel instead of silently hanging. There is no separate
        // "exec ack" callback in NIOSSH: the channel staying open after this
        // point means the request was accepted.
        let exec = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(exec, promise: nil)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        deliverExit(.closed)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let channelData = unwrapInboundIn(data)
        guard case .byteBuffer(let buf) = channelData.data else { return }
        // stdout and stderr are both delivered: the herdr bridge protocol runs
        // on stdout, but stderr carries the diagnostics when the remote command
        // (socat/python pump) fails — the bridge decides what to log.
        onOutput(buf)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let status as SSHChannelRequestEvent.ExitStatus:
            deliverExit(.status(status.exitStatus))
        case let signal as SSHChannelRequestEvent.ExitSignal:
            deliverExit(.signal(signal.signalName))
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Errors surface as a close; the exit callback carries `.closed` and the
        // bridge maps it to a transport failure (never fatal to the PTY path).
        context.close(promise: nil)
    }

    /// Write outbound bytes to the server as channel data.
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let buf = unwrapOutboundIn(data)
        let channelData = SSHChannelData(type: .channel, data: .byteBuffer(buf))
        context.write(wrapOutboundOut(channelData), promise: promise)
    }

    private func deliverExit(_ exit: ExecChannelExit) {
        guard !exitDelivered else { return }
        exitDelivered = true
        onExit(exit)
    }
}
