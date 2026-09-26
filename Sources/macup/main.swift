// Entry point. Commands live in Commands/; all provider, policy, and
// configuration logic lives in MacUpCore.
//
// Top-level code resolves `MacUpCommand.main()` to ArgumentParser's
// synchronous overload, which cannot run async subcommands. Calling it from an
// async function selects the async overload.
import Darwin
import Foundation

func runMacUp() async {
    // Never run the whole application as root (CLAUDE.md §2, item 8).
    if geteuid() == 0 {
        FileHandle.standardError.write(Data("error: MacUp does not run as root. Run it as your own user, without sudo.\n".utf8))
        exit(1)
    }
    await MacUpCommand.main()
}

await runMacUp()
