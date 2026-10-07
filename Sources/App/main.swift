import AppKit

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
