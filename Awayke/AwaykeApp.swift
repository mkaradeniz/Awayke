//
//  AwaykeApp.swift
//  Awayke
//

import AppKit

@main
struct AwaykeApp {
    static func main() {
        if CommandLine.arguments.dropFirst().first == "--cli" {
            exit(ControlCLI.run(arguments: Array(CommandLine.arguments.dropFirst(2))))
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
