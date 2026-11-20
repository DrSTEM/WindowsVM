# Security

Windows VM is early-access software. Use the latest source on `main`; older snapshots do not have a separate security maintenance policy.

## Report a vulnerability

Use GitHub's **Security → Report a vulnerability** for a private advisory in this repository. If private reporting is unavailable, open an issue saying only that you need a private reporting channel. Do not post an exploit, credentials, a guest disk, or sensitive logs publicly.

Include the affected revision, host and guest versions, a minimal reproduction, and the impact you observed. There is no guaranteed response time or commercial support commitment.

## Current boundaries

- The frontend and engine are not App Sandbox applications. They run with your user's access. A VM is not a guarantee that hostile guest software cannot affect the host.
- The engine helper uses the hypervisor entitlement. Experimental 3D adds a rendering worker and complex host graphics components to the guest-facing boundary.
- Normal display/control channels use private Unix sockets. No host port forwards, host folder sharing, or clipboard sharing are configured by default.
- Windows networking uses user-mode NAT when enabled. Guest software can still communicate over the network.
- Runtime setup checks the pinned upstream DMG digest, notarisation, app signature, team, and version. CocoaSpice is fetched by exact Git revision. Homebrew manages its own package verification.
- App bundles are ad hoc signed locally, not Developer ID signed or notarised by this project. The MIT source licence does not establish that a binary is safe or approved for redistribution.
- The project has no telemetry endpoint, hosted account system, or cloud sync. Dependencies, GitHub, Homebrew, Apple verification, Windows, and guest applications may make their own network requests.

Keep macOS, Windows, and guest software updated. Keep stopped whole-package backups, and retain guest recovery keys separately. Do not disable host security protections to make a failing build launch.
