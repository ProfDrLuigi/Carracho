#if CARRACHO_SERVER_DAEMON
import Foundation
import Darwin

@main
struct CarrachoServerDaemonMain {
    static func main() {
        guard let kind = CarrachoDaemonEntryPoint.requestedKind() else {
            fputs("Usage: carracho-serverd --daemon-server|--daemon-tracker [--server-root=PATH]\n", stderr)
            exit(64)
        }
        exit(CarrachoDaemonEntryPoint.run(kind: kind))
    }
}
#endif
