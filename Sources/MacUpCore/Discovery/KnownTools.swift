import Foundation

/// What a tool does, which decides how MacUp talks about it.
public enum ToolKind: String, Sendable, Hashable, CaseIterable {
    /// Installs and updates software: Homebrew, MacPorts, pipx, Cargo.
    case packageManager
    /// Installs and switches between versions of a language or runtime:
    /// mise, asdf, pyenv, rustup.
    case versionManager

    public var displayName: String {
        switch self {
        case .packageManager: "Package manager"
        case .versionManager: "Version manager"
        }
    }
}

/// A package manager or version manager MacUp can recognise on this Mac.
///
/// The catalog is deliberately wider than what MacUp manages: knowing that a
/// Mac also has pipx, Cargo, and rustup is worth saying even while MacUp
/// updates none of them, because an environment nobody can see whole is the
/// problem MacUp exists to fix (CLAUDE.md §0).
///
/// Everything here is read-only. A tool is found by resolving its executable
/// — never by running a shell — and the only command MacUp runs for it is the
/// fixed ``versionArguments`` array, which is also on
/// ``CommandAllowlist/toolScan``, so the scan is structurally unable to run
/// anything else.
public struct KnownTool: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    /// The executable's file name, for example `pipx`.
    public var executable: String
    /// The one read-only argument array that prints its version.
    public var versionArguments: [String]
    /// Where it is commonly installed. `~/` is expanded against the home
    /// directory.
    public var standardLocations: [String]
    /// Files that show the tool is installed when there is no executable to
    /// find, because it is a shell function. `~/` is expanded.
    public var markers: [String]
    public var kind: ToolKind
    /// What it keeps up to date, in the user's words.
    public var manages: String
    /// The MacUp provider that manages it, when one does.
    public var managedBy: ProviderID?

    public init(
        id: String,
        displayName: String,
        executable: String,
        versionArguments: [String] = ["--version"],
        standardLocations: [String] = [],
        markers: [String] = [],
        kind: ToolKind,
        manages: String,
        managedBy: ProviderID? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.executable = executable
        self.versionArguments = versionArguments
        self.standardLocations = standardLocations
        self.markers = markers
        self.kind = kind
        self.manages = manages
        self.managedBy = managedBy
    }

    /// `standardLocations` and `markers` with `~/` expanded.
    public func paths(_ paths: [String], homeDirectory: String) -> [String] {
        paths.map { $0.hasPrefix("~/") ? homeDirectory + $0.dropFirst() : $0 }
    }
}

extension KnownTool {
    /// The tools MacUp looks for, managed ones first.
    ///
    /// Adding one is a small trust decision: its ``versionArguments`` must be
    /// a documented, non-modifying command, and the matching rule must be on
    /// ``CommandAllowlist/toolScan`` or the scan refuses to run it.
    public static let catalog: [KnownTool] = managed + unmanaged

    /// The four a MacUp provider already manages, so the scan says so rather
    /// than listing them as something MacUp ignores.
    public static let managed: [KnownTool] = [
        KnownTool(
            id: "homebrew",
            displayName: "Homebrew",
            executable: "brew",
            standardLocations: ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"],
            kind: .packageManager,
            manages: "Formulae and casks",
            managedBy: .homebrew
        ),
        KnownTool(
            id: "npm",
            displayName: "npm",
            executable: "npm",
            standardLocations: ["/opt/homebrew/bin/npm", "/usr/local/bin/npm"],
            kind: .packageManager,
            manages: "Global Node packages",
            managedBy: .npm
        ),
        KnownTool(
            id: "mise",
            displayName: "mise",
            executable: "mise",
            standardLocations: ["~/.local/bin/mise", "/opt/homebrew/bin/mise", "/usr/local/bin/mise"],
            kind: .versionManager,
            manages: "Language runtimes and tools",
            managedBy: .mise
        ),
        KnownTool(
            id: "macos",
            displayName: "macOS Software Update",
            executable: "softwareupdate",
            versionArguments: [],
            standardLocations: ["/usr/sbin/softwareupdate"],
            kind: .packageManager,
            manages: "macOS and its updates",
            managedBy: .macos
        ),
    ]

    /// Found and named, managed by nobody yet. MacUp reads their versions and
    /// stops there: it proposes no update and runs no command of theirs.
    public static let unmanaged: [KnownTool] = [
        KnownTool(
            id: "macports",
            displayName: "MacPorts",
            executable: "port",
            versionArguments: ["version"],
            standardLocations: ["/opt/local/bin/port"],
            kind: .packageManager,
            manages: "Ports"
        ),
        KnownTool(
            id: "nix",
            displayName: "Nix",
            executable: "nix",
            standardLocations: ["~/.nix-profile/bin/nix", "/nix/var/nix/profiles/default/bin/nix", "/run/current-system/sw/bin/nix"],
            kind: .packageManager,
            manages: "Nix packages and profiles"
        ),
        KnownTool(
            id: "mas",
            displayName: "mas",
            executable: "mas",
            versionArguments: ["version"],
            standardLocations: ["/opt/homebrew/bin/mas", "/usr/local/bin/mas"],
            kind: .packageManager,
            manages: "Mac App Store apps"
        ),
        KnownTool(
            id: "pipx",
            displayName: "pipx",
            executable: "pipx",
            standardLocations: ["~/.local/bin/pipx", "/opt/homebrew/bin/pipx", "/usr/local/bin/pipx"],
            kind: .packageManager,
            manages: "Python applications"
        ),
        KnownTool(
            id: "uv",
            displayName: "uv",
            executable: "uv",
            standardLocations: ["~/.local/bin/uv", "~/.cargo/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"],
            kind: .packageManager,
            manages: "Python packages, and Python itself"
        ),
        KnownTool(
            id: "pip",
            displayName: "pip",
            executable: "pip3",
            standardLocations: ["/opt/homebrew/bin/pip3", "/usr/local/bin/pip3", "/usr/bin/pip3"],
            kind: .packageManager,
            manages: "Python packages"
        ),
        KnownTool(
            id: "poetry",
            displayName: "Poetry",
            executable: "poetry",
            standardLocations: ["~/.local/bin/poetry", "/opt/homebrew/bin/poetry", "/usr/local/bin/poetry"],
            kind: .packageManager,
            manages: "A Python project's packages"
        ),
        KnownTool(
            id: "conda",
            displayName: "conda",
            executable: "conda",
            standardLocations: ["~/miniconda3/bin/conda", "~/anaconda3/bin/conda", "~/miniforge3/bin/conda", "/opt/homebrew/bin/conda"],
            kind: .packageManager,
            manages: "conda environments and their packages"
        ),
        KnownTool(
            id: "cargo",
            displayName: "Cargo",
            executable: "cargo",
            standardLocations: ["~/.cargo/bin/cargo", "/opt/homebrew/bin/cargo", "/usr/local/bin/cargo"],
            kind: .packageManager,
            manages: "Rust crates and installed Rust binaries"
        ),
        KnownTool(
            id: "rustup",
            displayName: "rustup",
            executable: "rustup",
            standardLocations: ["~/.cargo/bin/rustup", "/opt/homebrew/bin/rustup"],
            kind: .versionManager,
            manages: "Rust toolchains"
        ),
        KnownTool(
            id: "gem",
            displayName: "RubyGems",
            executable: "gem",
            standardLocations: ["/opt/homebrew/bin/gem", "/usr/local/bin/gem", "/usr/bin/gem"],
            kind: .packageManager,
            manages: "Ruby gems"
        ),
        KnownTool(
            id: "go",
            displayName: "Go",
            executable: "go",
            versionArguments: ["version"],
            standardLocations: ["/opt/homebrew/bin/go", "/usr/local/go/bin/go", "/usr/local/bin/go"],
            kind: .packageManager,
            manages: "Go modules and installed Go binaries"
        ),
        KnownTool(
            id: "pnpm",
            displayName: "pnpm",
            executable: "pnpm",
            standardLocations: ["~/Library/pnpm/pnpm", "/opt/homebrew/bin/pnpm", "/usr/local/bin/pnpm"],
            kind: .packageManager,
            manages: "Node packages"
        ),
        KnownTool(
            id: "yarn",
            displayName: "Yarn",
            executable: "yarn",
            standardLocations: ["/opt/homebrew/bin/yarn", "/usr/local/bin/yarn"],
            kind: .packageManager,
            manages: "Node packages"
        ),
        KnownTool(
            id: "bun",
            displayName: "Bun",
            executable: "bun",
            standardLocations: ["~/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"],
            kind: .packageManager,
            manages: "Node packages, and Bun itself"
        ),
        KnownTool(
            id: "deno",
            displayName: "Deno",
            executable: "deno",
            standardLocations: ["~/.deno/bin/deno", "/opt/homebrew/bin/deno", "/usr/local/bin/deno"],
            kind: .packageManager,
            manages: "Deno packages, and Deno itself"
        ),
        KnownTool(
            id: "asdf",
            displayName: "asdf",
            executable: "asdf",
            standardLocations: ["~/.asdf/bin/asdf", "/opt/homebrew/bin/asdf", "/usr/local/bin/asdf"],
            kind: .versionManager,
            manages: "Language runtimes and tools"
        ),
        KnownTool(
            id: "volta",
            displayName: "Volta",
            executable: "volta",
            standardLocations: ["~/.volta/bin/volta", "/opt/homebrew/bin/volta"],
            kind: .versionManager,
            manages: "Node, npm, and Yarn versions"
        ),
        KnownTool(
            id: "pyenv",
            displayName: "pyenv",
            executable: "pyenv",
            standardLocations: ["~/.pyenv/bin/pyenv", "/opt/homebrew/bin/pyenv", "/usr/local/bin/pyenv"],
            kind: .versionManager,
            manages: "Python versions"
        ),
        KnownTool(
            id: "rbenv",
            displayName: "rbenv",
            executable: "rbenv",
            standardLocations: ["~/.rbenv/bin/rbenv", "/opt/homebrew/bin/rbenv", "/usr/local/bin/rbenv"],
            kind: .versionManager,
            manages: "Ruby versions"
        ),
        KnownTool(
            id: "jenv",
            displayName: "jenv",
            executable: "jenv",
            standardLocations: ["~/.jenv/bin/jenv", "/opt/homebrew/bin/jenv"],
            kind: .versionManager,
            manages: "Java versions"
        ),
        KnownTool(
            id: "composer",
            displayName: "Composer",
            executable: "composer",
            standardLocations: ["/opt/homebrew/bin/composer", "/usr/local/bin/composer"],
            kind: .packageManager,
            manages: "PHP packages"
        ),
        // Shell functions: there is no executable to resolve, so these are
        // found by the file their installer leaves and have no version.
        KnownTool(
            id: "nvm",
            displayName: "nvm",
            executable: "nvm",
            versionArguments: [],
            markers: ["~/.nvm/nvm.sh", "/opt/homebrew/opt/nvm/nvm.sh"],
            kind: .versionManager,
            manages: "Node versions"
        ),
        KnownTool(
            id: "sdkman",
            displayName: "SDKMAN!",
            executable: "sdk",
            versionArguments: [],
            markers: ["~/.sdkman/bin/sdkman-init.sh"],
            kind: .versionManager,
            manages: "JVM runtimes and tools"
        ),
    ]
}
