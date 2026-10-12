import Foundation

/// How a Hermes ACP child is launched. Production uses `hermes(path:)`. Tests build a shell
/// command through the same perl `setsid` launcher via `ACPLaunch.command` in the test bundle.
struct ACPLaunch: Sendable {
    var perl: URL
    var arguments: [String]

    static func hermes(path: URL) -> ACPLaunch {
        ACPLaunch(
            perl: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: [
                "-MPOSIX=setsid",
                "-e",
                "setsid(); exec {$ARGV[0]} @ARGV; exit 127",
                path.path,
                "-p",
                "voice",
                "acp"
            ]
        )
    }
}

enum ACPTransportError: Error {
    case terminated
    case launchFailed
    case closed
    case timedOut
    case writeFailed(Int32)
}

/// Newline-delimited JSON-RPC over a child process, or a scripted stand-in.
/// The child's pid is also its process-group id. A scripted transport reports nil.
protocol ACPTransport: AnyObject, Sendable {
    func start() throws
    /// `line` is JSON without a trailing newline. The transport appends exactly one.
    func send(line: Data) throws
    var lines: AsyncStream<Data> { get }
    func terminate()
    var processID: Int32? { get }
    var workingDirectory: URL { get }
    func setExitHandler(_ handler: @escaping @Sendable (_ uptime: TimeInterval) -> Void)
}
