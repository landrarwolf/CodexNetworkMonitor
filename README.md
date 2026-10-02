# Codex Network Monitor

**English** | [简体中文](README.zh-CN.md)

A lightweight macOS menu bar app that watches Codex connectivity, client disconnects, proxy / TUN routing, and your account's **5-hour and weekly quota**.

> An independent community project, unaffiliated with OpenAI. The app currently has a Chinese interface; documentation is available in both languages.

## Screenshots

These are rendered by the real app in **offline demo mode**. Quota, proxy ports, interfaces, timestamps, and logs are synthetic examples, not the author's account or network history.

| Connected with quota | Proxy failure with diagnosis |
| --- | --- |
| ![Demo: connected service and quota windows](docs/screenshots/healthy.png) | ![Demo: unreachable proxy listener](docs/screenshots/proxy.png) |

## Features

- A persistent status light and `5h余…% 周余…%` (remaining quota) in the menu bar.
- Click for the status panel; right-click to check, pause, or quit. An independent window is also available.
- Service checks every 15 seconds, combined with the running Codex process's logs to identify unresolved disconnects.
- HTTP / HTTPS / SOCKS system proxies, listener reachability, PAC configuration, and IPv4 / IPv6 default or global TUN routes.
- Comparison of the system path, a service request without the system proxy, and an ordinary website; a one-sentence local diagnosis.
- Account quota refreshed every minute: remaining, used, and reset time. Stale values carry `*`; missing values stay unknown.
- 15-minute / 1-hour / 24-hour history filters, errors only, copy summary, and export. Retention is capped at 7 days / 20,000 records.
- Optional disconnect / recovery notifications, off by default. Sleep is not counted as an outage; waking triggers a fresh check.

| Light | Meaning |
| --- | --- |
| 🟢 Connected | The service probe reaches HTTP and readable current-client logs have no recognized unresolved connection failure. |
| 🔴 Issue | The service path fails, or recent trustworthy client evidence indicates an unresolved failure. |
| ⚪ Unconfirmed | Starting, paused, sleeping, client absent, restricted 403 probe, unreadable logs, or expired disconnect evidence. |

## Install

Requires **macOS 14+** and an installed, signed-in Codex client.

1. Download the matching ZIP from [Releases](https://github.com/landrarwolf/CodexNetworkMonitor/releases/latest): `arm64` for Apple Silicon, `x86_64` for Intel.
2. Unzip, move `Codex Network Monitor.app` to Applications, and launch it.
3. Watch the menu bar. For startup at login, add the app yourself in System Settings → General → Login Items & Extensions.

Release builds are ad hoc signed, without Apple Developer ID signing or notarization. If macOS blocks a build, review and approve it yourself through the normal flow described by [Apple](https://support.apple.com/102445). The project does not require disabling Gatekeeper, certificate validation, or other system protections.

## Build from source

Use **Swift 6+**, including Swift Testing, from a recent Xcode or Command Line Tools installation. There are no third-party package dependencies.

```sh
git clone https://github.com/landrarwolf/CodexNetworkMonitor.git
cd CodexNetworkMonitor
zsh test.sh
zsh build.sh
open "dist/Codex Network Monitor.app"
```

The app and architecture-specific ZIP appear in `dist/`. Build and test caches default to the system temporary directory to avoid File Provider metadata breaking signing. Both scripts accept a custom cache directory as their first argument. Signing and archiving happen in the temporary directory; archives exclude Finder extended attributes.

## Diagnostics and screenshots

```sh
# These inspect the real network / account. Do not publish their output blindly.
"dist/Codex Network Monitor.app/Contents/MacOS/CodexNetworkMonitor" --diagnose
"dist/Codex Network Monitor.app/Contents/MacOS/CodexNetworkMonitor" --usage-diagnose

# Recreate README screenshots using offline synthetic fixtures.
zsh scripts/screenshots.sh
```

Use `--demo healthy|proxy --show-window` to inspect the demo interactively. `--render-preview PATH` saves the current interface as PNG and exits; combine it with `--demo` for public screenshots. Demo mode creates no real history store, starts no network sampler or CLI, reads no client logs, and requests no notification permission. It cannot be combined with live diagnostic flags.

`--data-dir PATH` selects a local data directory. `--show-window` opens an independent window at launch; closing it leaves menu bar monitoring active.

## Data and privacy

- Quota uses the installed Codex CLI's [app-server interface](https://learn.chatgpt.com/docs/app-server), sending only `initialize`, `initialized`, and `account/rateLimits/read`. No model generations, quota purchases, or reset redemptions.
- The CLI uses its existing login. This app does not read or copy authentication file contents and requires no API key. Normalized quota stays in memory; account IDs, balances, and authentication messages are not saved.
- Client log locations follow the [official troubleshooting documentation](https://learn.chatgpt.com/docs/reference/troubleshooting). Only controlled error categories and summaries are emitted, not raw chat, tokens, request bodies, or original log lines.
- Local `history.jsonl` lives under `~/Library/Application Support/Codex Network Monitor/`. Configuration records can include local proxy addresses and TUN interface names: review them before sharing. History is never automatically uploaded.
- The CLI runtime directory is `codex-runtime` within that local folder, with debug output and analytics disabled at launch. The app does not change proxies, TUN, certificates, Codex configuration, or login items.
- The repository contains source, docs, tests, and synthetic screenshots. A pre-publication check rejects common credentials, private paths, history, build artifacts, and PNG privacy metadata. It does not replace a human review of image pixels and Git history.

## Diagnostic limits

The primary probe sends an unauthenticated HEAD to `https://chatgpt.com/backend-api/codex/responses`. HTTP 401 / 404 / 405 means HTTP was reached; 403 remains inconclusive; 407, 429, and every 5xx are issues. An Apple test page is the control probe. Auxiliary checks run about once a minute when healthy and immediately on failure or configuration changes.

HTTP reachability does not establish that Codex's WebSocket or streaming requests recovered. Recognized failures are cleared by corresponding client recovery evidence. Evidence older than 24 hours, or with unreadable logs, becomes gray rather than implying recovery. Unknown custom remote executors contribute gray history records instead of controlling the core-client red light.

Requests without the system proxy still follow TUN routes and do not prove VPN bypass. System proxy settings may differ from Codex's actual path; PAC is detected but its script is not evaluated. Causes are local rule-based inferences, labeled suspected or unconfirmed when the evidence is insufficient.

The first log scan reads at most the trailing 2 MB per file, selecting 12 recent files plus the current process's files. History is not a complete copy of client logs, and error records are not distinct outage counts. Rules were checked against client `26.928.31416`; future log formats may require updates.

## Development

```sh
python3 scripts/check_public.py --self-test
python3 scripts/check_public.py
```

The second command checks Git-tracked / staged files. Stage new files with `git add` before checking. CI tests and builds on Apple Silicon and Intel macOS runners. See [CONTRIBUTING.md](CONTRIBUTING.md) for contributions and safe issue reports, and [CHANGELOG.md](CHANGELOG.md) for changes.

Licensed under [MIT](LICENSE).
