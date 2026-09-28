import MacUpAppCore

// The whole app lives in MacUpAppCore, which is a library so its logic can be
// tested. An executable target cannot be imported by a test target, and the
// model decides real things: whether a check may start, whether a change is
// approved, what the menu bar is allowed to claim. Only the entry point has to
// be here, so only the entry point is.
MacUpRoot.main()
