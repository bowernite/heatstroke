# macOS System Processes — Ignore List Research

Notes on why each category of Apple daemon is excluded from Heatstroke alerts.
These processes spike during normal operations and are not actionable by the user.

---

## Spotlight / Indexing

| Process | Role |
|---|---|
| `mds` | Spotlight metadata server — orchestrates all indexing |
| `mds_stores` | Writes/reads the Spotlight index database |
| `mdworker_shared` | Parallel workers that extract metadata from files |
| `mdworker` | Older per-file variant (pre-Big Sur); still appears on some setups |
| `corespotlightd` | Core Spotlight indexing daemon (introduced ~Monterey) |
| `spotlightknowledged` | Enriches the index with semantic/relational knowledge for Siri Suggestions and entity relationships |

All of these spike heavily after OS upgrades, on first boot, when connecting external drives, or when rebuilding a corrupted index. `spotlightknowledged` in particular has documented cases of running at 100–400% CPU when tied to iCloud Drive edge cases (e.g. specific Pages documents). [[source](https://mjtsai.com/blog/2025/12/02/runaway-spotlight-with-pages-document-on-icloud-drive/)] [[source](https://discussions.apple.com/thread/255762310)]

---

## Photos / Media Analysis

| Process | Role |
|---|---|
| `mediaanalysisd` | AI-based face recognition, object detection, Live Text (OCR), Visual Look Up, and semantic metadata for Photos and Spotlight |
| `photoanalysisd` | ML scene classification and face detection for Photos Smart Albums / Memories |
| `photolibraryd` | Photos library database management and metadata scanning |
| `cloudphotod` | iCloud Photos upload/download |

These spike for hours (or days) after large photo imports, after enabling iCloud Photos, or after OS upgrades.

> **Known issue — `mediaanalysisd`:** There is a well-documented class of Apple bugs (most recently macOS Sequoia 15.5, mid-2025) where `mediaanalysisd` spins at ~100% CPU for days and fills the drive with 15–140 GB of cache. This is a defect, not normal indexing. Workarounds involve clearing its cache directory or excluding folders from Spotlight. If Heatstroke ever adds duration-aware alerting (e.g., "still hot after 2 hours"), `mediaanalysisd` would be worth re-examining. [[source](https://zerosleeps.com/blog/2025/6/15/mediaanalysisd-has-gone-rogue/)] [[source](https://mjtsai.com/blog/2025/07/07/fixing-mediaanalysisd-storage-and-cpu-use/)] [[source](https://appleinsider.com/inside/macos-ventura/tips/how-to-stop-mediaanalysisd-from-hogging-your-cpu-in-macos)]

---

## iCloud / Sync

| Process | Role |
|---|---|
| `bird` | iCloud Drive file sync — moves files between local storage and iCloud |
| `cloudd` | CloudKit sync — iCloud Drive, app data, CloudKit containers |
| `nsurlsessiond` | HTTPS transfers for iCloud (Notes, Mail, Safari tabs, Messages), App Store, and other Apple services |
| `nsurlstoraged` | Manages local NSURLCache and web app storage (Safari, Mail, Calendar) |
| `accountsd` | Apple ID and third-party account credential management; spikes heavily after login or iCloud sync events |

Spike on network reconnect, after returning from offline, or when a large iCloud library syncs for the first time. [[source](https://osxdaily.com/2025/06/02/explaining-cloudd-photolibraryd-cloudphotod-processes-in-macos/)]

---

## Software Updates / Installation

| Process | Role |
|---|---|
| `softwareupdated` | Checks for, downloads, and stages macOS and App Store updates |
| `installd` | Installs/uninstalls apps and system components from PackageKit packages |
| `mobileassetd` | Downloads on-demand Apple system assets: timezone data, Siri voices, dictionaries, RAW camera profiles, fonts, firmware |
| `idleassetsd` | Downloads lock screen / screen saver video content (introduced in Sonoma); can spike heavily on initial setup |
| `storeaccountd` | App Store account daemon — manages purchases and entitlements |

These are finite, bounded operations. `mobileassetd` in particular spikes noticeably after every major OS upgrade as asset packs are refreshed.

---

## Security / Gatekeeper / XProtect

| Process | Role |
|---|---|
| `XProtectService` | Active malware scanning — runs on app launch and after modification |
| `XProtectRemediator` | Periodic scheduled malware remediation scanner (introduced in Monterey) |
| `syspolicyd` | Gatekeeper policy enforcement — validates code signatures and notarization; spikes on every new app launch |
| `amfid` | Apple Mobile File Integrity — enforces code signing and entitlement checks system-wide |
| `secd` | Keychain and Secure Enclave daemon — handles keychain access and certificate management |

These are scheduled or event-triggered and don't sustain high CPU for long under normal conditions. `secd` and `accountsd` can get into runaway loops tied to corrupt keychains, but that's an Apple bug rather than something a user should kill. [[source](https://iboysoft.com/wiki/xprotectservice.html)]

---

## Siri / Speech / On-Device ML

| Process | Role |
|---|---|
| `assistantd` | Core Siri daemon |
| `corespeechd` | CoreSpeech framework — speech recognition for dictation, Voice Control, and Siri; known to spike even when idle [[source](https://hackerdose.com/tips/fix-corespeechd-high-cpu-usage/)] |
| `suggestd` | Siri Suggestions engine — analyzes usage patterns for proactive Spotlight/Safari/Share sheet suggestions |
| `triald` | Manages Siri and ML model trial/update downloads |
| `intelligenceplatformd` | Apple Intelligence coordination (Sequoia+) |
| `neuralengined` | On-device neural inference orchestration — routes tasks to the Neural Engine |

---

## Network / Discovery

| Process | Role |
|---|---|
| `mDNSResponder` | Bonjour / multicast DNS — auto-discovery of printers, AirPlay, AirDrop, Handoff, file sharing |
| `networkd` | Core networking daemon |
| `netbiosd` | NetBIOS name service for SMB / Windows network compatibility |

---

## Time Machine / Backup

| Process | Role |
|---|---|
| `backupd` | Time Machine backup daemon — runs hourly, CPU/disk-intensive on first backup or after long gaps |
| `backupd-helper` | Assists with backup preparation and catalog management |

---

## Other System Services

| Process | Role |
|---|---|
| `locationd` | Core Location daemon — manages GPS and Wi-Fi positioning |
| `rapportd` | iPhone/iPad Handoff and Continuity relay daemon |
| `distnoted` | Distributed notifications server — processes inter-process notification bursts |
| `sharingd` | AirDrop, file sharing, and Continuity services |
| `diskimagesiod` | Disk image I/O daemon — active when mounting DMGs |
| `sandboxd` | Sandbox policy enforcement — evaluates violations; spikes on new app launches |
| `revisiond` | Document version history for NSDocument-based apps (Pages, TextEdit, etc.) |
| `oahd` | Rosetta 2 translation daemon (Apple silicon only) — AOT x86→ARM translation on first Intel binary run |
