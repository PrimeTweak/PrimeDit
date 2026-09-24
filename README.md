# PrimeDit

Filters Reddit's feeds and tidies its interface. Built for Reddit 2026.38.

- **Feed**: promoted posts, recommendations, NSFW, spoilers, suggestion cards, AI answers, visited posts
- **Filter lists**: keywords, communities, muted users
- **Posts and comments**: awards, vote counts, deleted comments, AutoMod collapse, colored thread lines
- **Interface**: tips and prompts, left menu sections
- **Tabs**: Chat apart from Inbox, Games tab, launch tab, hold You to switch accounts, keep the tab bar
  expanded
- **Refresh**: keep Home where you left it, confirm Home and pull-to-refresh reloads
- **Backup and reset** of all settings, cache size and auto-clear

Settings are in Reddit's Settings, under the **PrimeDit** button.

The .deb also works injected into an IPA (pyzule, cyan): its sideload fixes turn on only in a
re-signed app.

## Build

Actions → **Build** → Run workflow:

- **Debug**: IPA with the Compatibility tools, in the `debug` draft release
- **Release** (default branch only): IPA and debs, in a draft release to publish

The version is `Version:` in `control`. Release notes are its section in `CHANGELOG.md`.

## Credits

Based on [level3tjg](https://github.com/level3tjg)'s open-source Reddit tweak and its fork by NicholasBly; sideload
fixes adapted from level3tjg's RedditSideloadFix. [fishhook](https://github.com/facebook/fishhook) by Facebook is
fetched when the IPA is built. MIT License.
