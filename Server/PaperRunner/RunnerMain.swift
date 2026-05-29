import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
enum BucksCopyPaperRunnerMain {
    static func main() async {
        do {
            let config = try PaperRunnerConfig.fromEnvironment()
            let runner = try PaperRunner(config: config)

            if config.runOnce {
                try await runner.runOnce()
                return
            }

            while true {
                try await runner.runOnce()
                try await Task.sleep(nanoseconds: config.pollIntervalNanoseconds)
            }
        } catch is CancellationError {
            return
        } catch {
            FileHandle.standardError.write(
                Data("BucksCopyPaperRunner fatal: \(PaperRunnerErrorText.publicDescription(error))\n".utf8)
            )
            exit(1)
        }
    }
}
