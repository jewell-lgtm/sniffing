import AppKit

@main
@MainActor
enum Main {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty {
            MenuBarApp.run()
        } else {
            exit(CLI.run(args))
        }
    }
}
