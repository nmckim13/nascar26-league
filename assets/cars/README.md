# BARL driver car artwork

Created September 17, 2026 with the built-in image generation tool. The 12 WebP assets cover every active car assignment in the public league roster at creation time. Profiles take names and numbers from live league data; no names are baked into these images.

## References

Layout direction: [Formula 1 drivers](https://www.formula1.com/en/drivers) and the supplied team-card screenshot.

Paint schemes: [The Daily Downforce — NASCAR 26 base paint schemes](https://dailydownforce.com/every-base-paint-scheme-in-iracings-nascar-26-console-game/). These are AI-rendered interpretations of the game references, not official game exports; obscured rear bodywork has been reconstructed.

## Assets

| Car | Website asset | Paint reference |
| --- | --- | --- |
| 5 | [5.webp](5.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/8C603668-F212-4C48-B4D4-756F854B296F_1_105_c.jpeg) |
| 6 | [6.webp](6.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/ABD55A13-768F-4487-8891-0D62688BC26B_1_105_c.jpeg) |
| 7 | [7.webp](7.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/4B0C32A3-DB03-4202-A699-960705D1CC53_1_105_c.jpeg) |
| 9 | [9.webp](9.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/6BABA603-12AD-42F8-A4D8-A7DD9630622A_1_105_c.jpeg) |
| 17 | [17.webp](17.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/9523920E-50BC-4E34-99FA-4BCBD3912C2B_1_105_c.jpeg) |
| 19 | [19.webp](19.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/FC6E05E4-2723-49D7-B952-DC427394B1A0_1_105_c.jpeg) |
| 20 | [20.webp](20.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/71ADD9BE-0F71-45A4-A436-1AA5E935D2DD_1_105_c.jpeg) |
| 24 | [24.webp](24.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/A81F8141-E507-4AF0-B79F-A8EBFFE924B9_1_105_c.jpeg) |
| 54 | [54.webp](54.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/707BC720-5ED6-422F-BB51-EA2887776474_1_105_c.jpeg) |
| 60 | [60.webp](60.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/4362C11A-19ED-4495-880D-A6B53E0751F4_1_105_c.jpeg) |
| 88 | [88.webp](88.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/78C5E2B8-85EA-4D3B-B5B0-30A1D795105B_1_105_c.jpeg) |
| 97 | [97.webp](97.webp) | [Source screenshot](https://dailydownforce.com/wp-content/uploads/2026/09/A6132F77-4734-4A87-84E1-2A0EBBB379E5_1_105_c.jpeg) |

Full generation prompts and the #97 sponsor correction are saved in [prompts.json](prompts.json). Images were converted to WebP at quality 88 for the website. Original generation PNGs remain in the Codex generated-images folder.

## Integration

`data/car-art.js` maps car numbers to sponsors, makes, and accent colors. `scripts/profile-car-card.js` renders a native career-profile link with live name/number text. `profile-cards.css` controls the responsive two-column/one-column presentation. Unknown future car numbers get a clearly labeled placeholder instead of an incorrect livery.

Both preseason and active-season paths in `profiles.html` use the shared cards. Active-season statistics and career breakdowns remain available.

## Matching number badges

Header numbers use paint-specific artwork through `numberImage` in the car catalog. The existing #19, #88 and #97 decals are reused. Nine badges under `numbers/` were reconstructed from the displayed car-door numerals with the built-in image generation tool. Generation prompts are in `numbers/prompts.json`.

Car images use normal compositing in an isolated stage, above the halftone background. They never use lighten/screen blending, which would let background dots show through dark bodywork.

## Transparent car backgrounds

The eleven original studio-background renders were edited into transparent cutouts, matching the existing #7 asset. This exposes the card's color and halftone pattern around the car while preserving the bodywork and tires. The extraction prompt and source outputs are recorded in `cutout-prompts.json`. Website images retain their alpha channel when converted to WebP.
