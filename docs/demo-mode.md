# Demo mode: a Telegram that never talks to Telegram

The build ships as a fake Telegram by default. No request reaches a server: authorization completes
locally, the account's network is pinned to a closed loopback SOCKS5 proxy, and the postbox is seeded
with fake peers, messages and star gifts. Everything the app then does — sending, gifts, Stars,
upgrades — is answered from local state.

Launch with `--real` to opt out and get the regular Telegram sign-in.

The whole design lives in [`submodules/TelegramCore/Sources/DemoMode.swift`](../submodules/TelegramCore/Sources/DemoMode.swift);
the demo branches in the rest of the codebase are all `if DemoMode.isEnabled` and are documented at
the call site.

## What is fake, and how

| Real Telegram | Demo mode |
| --- | --- |
| Phone-code sign-in | `Authorization.swift` completes locally, then `demoSeedPostbox` fills the account on first login (idempotent: it returns immediately if the chat list is not empty) |
| MTProto connection | `AppDelegate` writes `DemoMode.hermeticProxySettings()` (SOCKS5 → `127.0.0.1:1`) before the first account; `shouldKeepAutoConnection` is `false`; `Account.networkState` reports `.single(.online)` so the UI reads as connected |
| `messages.sendMessage` | `enqueueMessages` diverts to `demoEnqueueMessages`, which writes the message straight into the cloud history as delivered — no pending queue, nothing that can fail or show as "sending" |
| `payments.*` (gifts, upgrades, transfers) | Each `_internal_*` entry point takes a `demo*` helper from `DemoMode.swift` that rewrites the postbox the same way the server would have |
| `payments.getSavedStarGifts` | `demoProfileGifts` reads the gift service messages back out of the seeded histories |
| App configuration / app store products | `DemoMode.demoTopUpOptions` and `demoGiftOptions` seed the Stars and gift catalogues; `StarsProduct.storeProduct` is nil, so `buy()` fakes a 0.6 s purchase and credits the balance |

Stars balances live in `UserDefaults` (`DemoMode.starsBalance`, 12 500 to start). Spending is
clamped at 0; the balance is re-published by `StarsContextImpl.load(force:)`.

## Message limits

There are none, deliberately:

- **Length.** `breakChatInputText` returns the whole text as one piece while the demo is on, so a
  long message is sent as a single message instead of being split at 4096 characters. The edit-mode
  remaining-count counter and its send-blocking shake are disabled too (`ChatTextInputPanelNode`,
  `AttachmentTextInputPanelNode` for media captions).
- **Rate.** Demo sends never enter `PendingMessageManager`, so `sendMessageReasonForError` — which
  maps `PEER_FLOOD`, `SENDING_TOO_FAST`, `SLOWMODE_WAIT` — is unreachable, and no `CachedChannelData`
  is ever seeded, so `slowmodeState` is nil and no slowmode UI appears.

Deliberately **not** changed: the broadcast channel «Новости Telegram» still refuses input the way a
real subscriber-only channel does, and chat history is still the seeded few dozen messages — scrolling
up hits the end.

## Gifts

Seeded catalogue: 900001 🎁 15★, 900002 🧸 25★, 900003 💍 50★ (upgradable, 250★), 900004 🎂 100★
(upgradable, 500★, birthday), 900005 🎈 150★, 900006 🐈 250★. Gift pictures are gzipped Lottie
(`application/x-tgsticker`), recoloured six ways and embedded as base64 in `DemoMode.swift`.

Implemented end to end, offline:

- sending a star gift or a Premium gift from the chat (`GiftSetupScreen` writes the service message
  and debits the fake balance);
- the profile Gifts tab, both on your own profile and on someone else's;
- upgrade to a collectible (attributes, preview, price, balance row, the upgrade animation, the
  minted `slug: "star:<giftId>:<number>"` and the value statistics behind "Learn more");
- convert to Stars, delete from profile, pin/hide (`savedToProfile`);
- collections: create, rename, reorder, delete;
- resale: list, unlist, price row;
- transfer: the collectible leaves your profile and is written into the recipient's chat, and their
  `starGiftsCount` is bumped so their Gifts tab opens on it;
- wearing a gift as an emoji status: `setStarGiftStatus` writes the peer's `emojiStatus` into the
  postbox first and only then fires the (swallowed) network call, so it persists offline.

Not implemented, and gated off in the UI rather than left to fail: buying someone else's listed
collectible (`buyStarGift`, the resale store), moving a gift to a TON wallet, dropping the original
details, and gift offers — all of them need `minOfferStars` / `dropOriginalDetailsStars` /
`prepaidUpgradeHash`, which the demo leaves nil.

## Building

There is no per-module build; the whole `Telegram/Telegram` target is built with Bazel through
`Make.py`, on macOS:

```sh
source ~/.zshrc 2>/dev/null
python3 build-system/Make/Make.py --overrideXcodeVersion --cacheDir ~/telegram-bazel-cache \
  build \
  --configurationPath build-system/appstore-configuration.json \
  --gitCodesigningRepository git@gitlab.com:peter-iakovlev/fastlanematch.git \
  --gitCodesigningType development --gitCodesigningUseCurrent --buildNumber=1 \
  --configuration=debug_sim_arm64
```

`TELEGRAM_CODESIGNING_GIT_PASSWORD` must be in the environment (`~/.zshrc` sets it), hence the
`source` line. Add `--continueOnError` after `build` to collect every error in one pass.

See [`CLAUDE.md`](../CLAUDE.md) for simulator driving (XcodeBuildMCP), installing a rebuilt `.app`
over an existing install, and running tests. `Make.py test --target <label>` runs a single
`ios_unit_test`; `Tests/AllTests` currently references a dangling target, so always pass `--target`.

**This repository cannot be compiled on Windows** — there is no `swiftc`, no Xcode and no Bazel toolchain
for the Apple targets here. On Windows the most that can be done is static checking.

## Static checks

Three scripts in [`tools/`](../tools), run from the repository root with the touched files as
arguments, catch the mistakes this codebase actually makes:

```sh
python tools/balance_check.py   submodules/.../SomeFile.swift   # {} () [] all balanced
python tools/paren_depth.py     submodules/.../SomeFile.swift   # paren depth 0 at EOF
python tools/arity_check.py     submodules/.../DemoMode.swift   # star-gift patterns/constructors match
```

`arity_check.py` matters whenever a `.starGift` / `.starGiftUnique` pattern or constructor is touched:
the enums have 22–23 labeled fields, and a wrong arity or a reordered label compiles as a different
shape only sometimes. `tools/test_checkers.py` proves the two checkers themselves.
