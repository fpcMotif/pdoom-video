// pdoom-native: CLI entry point. Subcommands: diagnostic, post-fixture, stills, video (see README / the
// coordinator's brief for the exact shape). M1 implements `diagnostic`; M2 implements `post-fixture`.
import Foundation
import PdoomCore

@main
struct Main {
  static func main() async {
    // A dead ffmpeg child closes its stdin pipe; without this, writing to it delivers SIGPIPE and kills
    // us before our own error handling (partial-file cleanup, a clean nonzero exit) can run.
    signal(SIGPIPE, SIG_IGN)
    let argv = Array(CommandLine.arguments.dropFirst())
    guard let mode = argv.first else {
      FileHandle.standardError.write("usage: pdoom-native diagnostic|post-fixture|stills|video ... [--root DIR]\n".data(using: .utf8)!)
      exit(2)
    }
    let args = Args(Array(argv.dropFirst()))
    do {
      let root = try findRepoRoot(explicit: args.opt("root"))
      switch mode {
      case "diagnostic": try await runDiagnostic(args: args, root: root)
      case "post-fixture": try runPostFixture(args: args, root: root)
      case "stills": try await runStills(args: args, root: root)
      case "video": try await runVideo(args: args, root: root)
      default:
        FileHandle.standardError.write("unknown subcommand '\(mode)'\n".data(using: .utf8)!)
        exit(2)
      }
    } catch {
      FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
      exit(1)
    }
  }
}

func requireOpt(_ args: Args, _ key: String) throws -> String {
  guard let v = args.opt(key) else { throw EncoderError.failed("--\(key) is required") }
  return v
}

// -------------------------------------------------------------------------------------------- stubs (M3)
func runStills(args: Args, root: URL) async throws {
  throw EncoderError.failed("stills: not implemented yet (M3)")
}
func runVideo(args: Args, root: URL) async throws {
  throw EncoderError.failed("video: not implemented yet (M3)")
}
