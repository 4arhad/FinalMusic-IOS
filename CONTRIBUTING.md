# Contributing to Final Music

Thanks for your interest in improving Final Music, an independent SwiftUI music client.

## Before you start

- Read the [README](README.md) to understand the architecture and supported features.
- Search existing issues and pull requests before starting work.
- For a large feature or architecture change, open an issue first to discuss the approach.
- Be respectful and constructive in all discussions.

## Development setup

1. Fork this repository and clone your fork.
2. Open `FinalMusic.xcodeproj` in Xcode on a Mac.
3. Select an available iOS simulator and build the app.
4. For core checks, run `swift run FinalMusicCoreChecks` from the repository root on a compatible Swift toolchain.
5. Keep credentials and signing material on your own machine. Never commit API keys, cookies, tokens, provisioning profiles, or certificates.

Some integrations (such as Last.fm, YouTube account sync, and CarPlay) may require separate configuration, permissions, or entitlements. Document any setup requirements in your pull request.

## Proposing changes

1. Create a focused branch from `main`.
2. Make one logical change per pull request.
3. Add or update tests when changing testable core logic.
4. Verify that your change builds and describe what you tested. If you cannot test something, say so.
5. Open a pull request with a clear summary, screenshots for UI changes, and links to related issues.

## Pull request checklist

- [ ] I have explained the change and its motivation.
- [ ] I have tested the relevant code, or explained why I could not.
- [ ] I have not committed credentials, personal information, or generated build output.
- [ ] I have documented new settings or user-visible behavior.
- [ ] I have checked the rights and licenses for any code or assets I added.

## Good first contributions

Documentation, accessibility, reproducible bug reports, test coverage, and small UI improvements are especially welcome. Look for issues labeled `good first issue` or `help wanted` when available.

## Legal and content considerations

Respect the licenses of upstream projects and dependencies. Do not submit copyrighted media or other assets without permission. Streaming integrations must be reviewed for compatibility with applicable service terms and distribution requirements.

The repository currently has no top-level LICENSE file. Until the maintainers choose a license and confirm upstream obligations, do not assume that the code is available for unrestricted reuse or redistribution.
