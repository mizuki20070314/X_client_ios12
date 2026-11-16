# Third-party notices

## Lucide (icon shapes)

Most icon shapes in `ios/XRelayClient/UI/Foundation/IconData.swift` come from **Lucide**
(https://lucide.dev), an open icon set. The app uses only the shapes; no artwork from any
other project is used, and none of these icons comes from X's apps.

The Lucide SVG files are kept in `tools/icons/svg/`. They were downloaded on 2026-11-16 from
https://github.com/lucide-icons/lucide (branch `main`). `tools/build_icons.py` converts them to
path data, and `tools/icons/icons.json` lists the parts used for each icon.

Lucide has renamed some icons. Where the name in the design table was not found, the
substitutes below are used:

- `trash` uses Lucide `trash` (the design table names `trash-2`, which is no longer in Lucide).
- `history` and `alert` are built from several parts; see "Combined icons" below.

### Icons taken from Lucide

| Lucide file | Icon names |
|---|---|
| `search.svg` | `search`, `searchBold` (drawn with stroke width 2.75) |
| `bell.svg` | `bell` (`bellFill` uses its outline and clapper, see below) |
| `message-circle.svg` | `message`, `messageFill`, `reply` |
| `repeat-2.svg` | `repost` |
| `heart.svg` | `heart`, `heartFill` |
| `bookmark.svg` | `bookmark`, `bookmarkFill` |
| `share-2.svg` | `share` |
| `plus.svg` | `plus` |
| `x.svg` | `close` |
| `arrow-left.svg` | `back` |
| `chevron-right.svg` | `chevronRight` |
| `chevron-down.svg` | `chevronDown` |
| `settings.svg` | `settings` |
| `user.svg` | `person`, `personFill` |
| `user-plus.svg` | `userPlus` |
| `user-minus.svg` | `userMinus` |
| `pin.svg` | `pin` |
| `lock.svg` | `lock` |
| `link.svg` | `link` |
| `map-pin.svg` | `mapPin` |
| `calendar-days.svg` | `calendar` |
| `mail.svg` | `mail` |
| `image.svg` | `image` |
| `trash.svg` | `trash` |
| `volume-x.svg` | `volumeOff` |
| `ban.svg` | `ban` |
| `flag.svg` | `flag` |
| `copy.svg` | `copy` |
| `external-link.svg` | `external` |
| `sun.svg` | `sun` |
| `moon.svg` | `moon` |
| `pen-line.svg` | `pencil` |
| `rotate-cw.svg` | `refresh` |
| `check.svg` | `check` |
| `star.svg` | `star` (drawn filled) |
| `info.svg` | `info` |
| `trending-up.svg` | `trending` |
| `at-sign.svg` | `at` |
| `send.svg` | `send` |

### Combined icons

- `history`: Lucide `rotate-ccw` with our own clock hands (Lucide `history` is no longer in the set).
- `alert`: Lucide `triangle` with our own exclamation mark (Lucide `triangle-alert` is no longer in the set).
- `bellFill`: the outline of Lucide `bell`, copied and filled, with its clapper stroked.
- `verified`: the outline of Lucide `badge-check`, copied and filled, with its check mark cut out.

### Icons designed for this app

`home`, `homeFill`, `views`, `overflow`, `more`, `logo` and `play` are our own shapes.

## Lucide licence

The text below is the `LICENSE` file of the Lucide repository, as downloaded on 2026-11-16 from
https://raw.githubusercontent.com/lucide-icons/lucide/main/LICENSE. It contains the ISC licence
and, for the icons derived from Feather, the MIT notice.

```text
ISC License

Copyright (c) 2026 Lucide Icons and Contributors

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

---

The following Lucide icons are derived from the Feather project:

airplay, alert-circle, alert-octagon, alert-triangle, aperture, arrow-down-circle, arrow-down-left, arrow-down-right, arrow-down, arrow-left-circle, arrow-left, arrow-right-circle, arrow-right, arrow-up-circle, arrow-up-left, arrow-up-right, arrow-up, at-sign, calendar, cast, check, chevron-down, chevron-left, chevron-right, chevron-up, chevrons-down, chevrons-left, chevrons-right, chevrons-up, circle, clipboard, clock, code, columns, command, compass, corner-down-left, corner-down-right, corner-left-down, corner-left-up, corner-right-down, corner-right-up, corner-up-left, corner-up-right, crosshair, database, divide-circle, divide-square, dollar-sign, download, external-link, feather, frown, hash, headphones, help-circle, info, italic, key, layout, life-buoy, link-2, link, loader, lock, log-in, log-out, maximize, meh, minimize, minimize-2, minus-circle, minus-square, minus, monitor, moon, more-horizontal, more-vertical, move, music, navigation-2, navigation, octagon, pause-circle, percent, plus-circle, plus-square, plus, power, radio, rss, search, server, share, shopping-bag, sidebar, smartphone, smile, square, table-2, tablet, target, terminal, trash-2, trash, triangle, tv, type, upload, x-circle, x-octagon, x-square, x, zoom-in, zoom-out

The MIT License (MIT) (for the icons listed above)

Copyright (c) 2013-present Cole Bemis

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
