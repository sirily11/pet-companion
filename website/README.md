# PetPaw website

A responsive Next.js landing page for PetPaw, with a Material 3 inspired navigation rail, tonal surfaces, rounded cards, pill buttons, light/dark themes, and generated character artwork.

## Run locally

Use Node.js 22 LTS (22.13 or later) or a newer LTS release.

```sh
cd website
npm ci
npm run dev
```

Open http://localhost:3000.

## Validate and build

```sh
npm run lint
npm run typecheck
npm run build
```

The production build is a static export in `out/`. Serve that folder with any static host. The development server supports local preview; `next start` does not serve static exports.

Social preview URLs default to `https://pet.rxlab.app`. To deploy on another host, copy `.env.example` to `.env.local` and set `NEXT_PUBLIC_SITE_URL` to that host's public URL before building.

## Social previews

The dedicated 1200×630 JPEG sharing card is `src/app/opengraph-image.jpg`, with accessible text in `src/app/opengraph-image.alt.txt`. Next.js's file-based metadata includes its image URL, type, dimensions, and alt text in the page head and exports the image with the static site. Twitter uses the same image with a `summary_large_image` card. The image is included even when `NEXT_PUBLIC_SITE_URL` is unset, using the default public URL.

The card was generated with the built-in imagegen tool using the existing hero kitten as a reference. Its prompt is in `design/image-prompts.md`.

## Downloads

All app buttons link directly to the latest stable GitHub release asset:

`https://github.com/sirily11/pet-companion/releases/latest/download/PetCompanion.dmg`

The release workflow uses the stable `PetCompanion.dmg` filename, so links follow new releases automatically. The setup section links to the pet import guide, without offering a separate pet package download. Update these URLs in `src/lib/links.ts` if repository ownership or asset names change.

The page follows [Material 3](https://m3.material.io/). Generated images live in `public/images/`; the image generation prompts and reference attribution are in `design/image-prompts.md`. The generated scenes are illustrations, not app screenshots. The favicon uses the app’s existing icon.

DM Sans loads from Google Fonts with a local system-font fallback. No credentials, backend, or AI service is needed to run this website. The theme and character preview are local page interactions.
