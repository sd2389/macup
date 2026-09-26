// Entry point. Commands live in Commands/; all provider, policy, and
// configuration logic lives in MacUpCore.
//
// Top-level code resolves `MacUpCommand.main()` to ArgumentParser's
// synchronous overload, which cannot run async subcommands. Calling it from an
// async function selects the async overload.
func runMacUp() async {
    await MacUpCommand.main()
}

await runMacUp()
