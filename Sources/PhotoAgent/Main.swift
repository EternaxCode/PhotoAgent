import Foundation

@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        if arguments.contains("--cli") {
            exit(CLIRunner.run(arguments: arguments))
        }
        PhotoAgentApp.main()
    }
}
