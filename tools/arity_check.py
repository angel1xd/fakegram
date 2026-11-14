"""Check that every star-gift enum pattern and constructor in the demo files has the
right number of arguments, in the right order.

Usage: python arity_check.py <file> [<file> ...]
"""
import io
import re
import sys

STAR_GIFT = ['gift', 'convertStars', 'text', 'entities', 'nameHidden', 'savedToProfile',
             'converted', 'upgraded', 'canUpgrade', 'upgradeStars', 'isRefunded',
             'isPrepaidUpgrade', 'upgradeMessageId', 'peerId', 'senderId', 'savedId',
             'prepaidUpgradeHash', 'giftMessageId', 'upgradeSeparate', 'isAuctionAcquired',
             'toPeerId', 'number']
STAR_GIFT_UNIQUE = ['gift', 'isUpgrade', 'isTransferred', 'savedToProfile', 'canExportDate',
                    'transferStars', 'isRefunded', 'isPrepaidUpgrade', 'peerId', 'senderId',
                    'savedId', 'resaleAmount', 'canTransferDate', 'canResaleDate',
                    'dropOriginalDetailsStars', 'assigned', 'fromOffer', 'canCraftAt',
                    'isCrafted', 'text', 'entities', 'nameHidden']
STATE_STAR_GIFT = ['gift', 'reference', 'fromPeer', 'date', 'text', 'entities', 'nameHidden',
                   'savedToProfile', 'pinnedToTop', 'convertStars', 'canUpgrade',
                   'canExportDate', 'upgradeStars', 'transferStars', 'canTransferDate',
                   'canResaleDate', 'collectionIds', 'prepaidUpgradeHash', 'upgradeSeparate',
                   'dropOriginalDetailsStars', 'number', 'isRefunded', 'canCraftAt']
UNIQUE_GIFT = ['id', 'giftId', 'title', 'number', 'slug', 'owner', 'attributes', 'availability',
               'giftAddress', 'resellAmounts', 'resellForTonOnly', 'releasedBy', 'valueAmount',
               'valueCurrency', 'valueUsdAmount', 'flags', 'themePeerId', 'peerColor',
               'hostPeerId', 'minOfferStars', 'craftChancePermille']
VALUE_INFO = ['isLastSaleOnFragment', 'valueIsAverage', 'value', 'currency', 'initialSaleDate',
              'initialSaleStars', 'initialSalePrice', 'lastSaleDate', 'lastSalePrice',
              'floorPrice', 'averagePrice', 'listedCount', 'fragmentListedCount',
              'fragmentListedUrl']

CASES = [('starGift', STAR_GIFT), ('starGiftUnique', STAR_GIFT_UNIQUE)]
CALLS = [('ProfileGiftsContext.State.StarGift(', STATE_STAR_GIFT),
         ('StarGift.UniqueGift(', UNIQUE_GIFT),
         ('StarGift.UniqueGift.ValueInfo(', VALUE_INFO),
         ('.starGiftUnique(', STAR_GIFT_UNIQUE),
         ('.starGift(', STAR_GIFT)]


def call_args(text, open_index):
    """Return the top-level argument list of the call whose '(' is at open_index."""
    depth = 0
    parts = []
    buf = ''
    for k in range(open_index, len(text)):
        c = text[k]
        if c == '(':
            depth += 1
            if depth == 1:
                continue
        elif c == ')':
            depth -= 1
            if depth == 0:
                parts.append(buf)
                break
        if depth == 1 and c == ',':
            parts.append(buf)
            buf = ''
            continue
        if depth >= 1:
            buf += c
    return [p.strip() for p in parts if p.strip()]


def line_of(text, index):
    return text.count('\n', 0, index) + 1


def main(paths):
    problems = 0
    for path in paths:
        text = io.open(path, encoding='utf-8').read()

        # Patterns: case let .starGift(...) = ...
        for name, expected in CASES:
            for m in re.finditer(r'case let \.' + name + r'\(', text):
                inner = call_args(text, text.index('(', m.end() - 1))
                labels = [a.split(':')[0].strip() for a in inner]
                is_pattern = ':' not in inner[0] if inner else True
                if not is_pattern:
                    continue
                # Api decode patterns bind one `...Data` tuple; they are a different enum.
                if len(inner) == 1 and inner[0].endswith('Data'):
                    continue
                bad = check(labels, expected, 'pattern', name)
                if bad:
                    problems += 1
                    print('%s:%d %s: %s' % (path, line_of(text, m.start()), name, bad))

        # Constructor calls (labelled).
        for needle, expected in CALLS:
            start = 0
            while True:
                idx = text.find(needle, start)
                if idx < 0:
                    break
                open_index = text.index('(', idx + len(needle) - 1)
                inner = call_args(text, open_index)
                labels = [a.split(':')[0].strip() for a in inner]
                if labels and ':' in labels[0]:
                    bad = check(labels, expected, 'call', needle.rstrip('('))
                    if bad:
                        problems += 1
                        print('%s:%d %s: %s' % (path, line_of(text, idx), needle.rstrip('('), bad))
                start = open_index + 1

    if problems == 0:
        print('OK: all star-gift patterns and constructors match')
    return 1 if problems else 0


def check(labels, expected, kind, name):
    if len(labels) != len(expected):
        return '%s has %d args, expected %d (%s)' % (kind, len(labels), len(expected),
                                                     ', '.join(labels[:25]))
    if kind == 'call':
        for i, (got, want) in enumerate(zip(labels, expected)):
            if got != want:
                return 'arg %d is %s, expected %s' % (i + 1, got, want)
    else:
        for i, (got, want) in enumerate(zip(labels, expected)):
            if got != '_' and got != want:
                return 'binding %d is %s, expected %s' % (i + 1, got, want)
    return None


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
