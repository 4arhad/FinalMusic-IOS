# Final Music Roadmap

This document describes **proposed** priorities, not promised releases. Contributions and discussion are welcome.

## Current baseline

According to the project README, Final Music already includes SwiftUI browsing and search, local library and playlists, playback controls, lyrics, account integrations, artwork caching, and CarPlay-related code. Some features depend on external services, configuration, or entitlements.

## Priority 1 — Reliability and contributor experience

- [ ] Document a reproducible Xcode build and simulator setup.
- [ ] Add a pull-request build/check workflow once the supported Xcode version and signing-free build command are verified.
- [ ] Expand core checks for queue management, caching policies, and integration parsing.
- [ ] Improve error messages and recovery for unavailable streams or network failures.
- [ ] Review accessibility labels, Dynamic Type, and VoiceOver navigation.

## Priority 2 — Playback and performance

- [ ] Profile scrolling, image loading, memory use, and app launch on real devices.
- [ ] Test interruptions, audio route changes, lock-screen controls, and background playback.
- [ ] Add regression tests for queue edits, shuffle/repeat behavior, and stream failures.
- [ ] Review cache limits and offline behavior without implying offline playback support.

## Priority 3 — Integrations and polish

- [ ] Validate CarPlay behavior on supported setups with required entitlements.
- [ ] Improve integration setup documentation and user-facing error states.
- [ ] Refine search, playlist management, and player accessibility.
- [ ] Collect community feedback on navigation and UI consistency.

## Community milestones

- [ ] Confirm upstream license obligations and choose a compatible project license.
- [ ] Publish issue templates and label beginner-friendly tasks.
- [ ] Add a contributor code of conduct if the community grows.
- [ ] Review external service terms and distribution constraints before public releases.

## Suggest an idea

Open an issue explaining the problem, expected behavior, and proposed solution. Please avoid submitting credentials or private account information.
