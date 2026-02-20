# Normies

Fully on-chain generative NFT collection — 10,000 unique 40x40 monochrome pixel art faces with encrypted pre-reveal
storage and on-chain SVG rendering.

## Architecture

```
┌──────────────────┐    ┌──────────────────┐     ┌──────────────────┐
│  NormiesMinter   │--->│     Normies      │     │  NormiesStorage  │
│  NormiesMinterV2 │--->│   (ERC721C NFT)  │     │    (SSTORE2)     │
└──────────────────┘    └────────┬─────────┘     └────────┬─────────┘
        |                        |                        ^
        |                        | tokenURI()             |
        |                        v                        |
        │               ┌──────────────────┐              │
        │               │ NormiesRenderer  │──────────────┘
        │               │ V1 / V2 / V3     │  reads image + traits
        │               └────────┬─────────┘
        │                        │
        └────────────────────────┘
                writes image + traits
                to storage on mint

┌──────────────────┐
│  NormiesTraits   │  ← trait name library used by renderers
└──────────────────┘
```

## Contracts

### Normies.sol

Core ERC721C token contract with ERC-2981 royalties, modular renderer/storage references, and authorized minter access
control. Supports burn and owner-controlled metadata refresh signals.

### NormiesStorage.sol

Stores encrypted 200-byte monochrome bitmaps via SSTORE2 and packed `bytes8` trait data per token. Uses XOR encryption
with a keccak256-derived keystream — data remains encrypted on-chain until the owner sets the reveal hash. Once
revealed, reads automatically decrypt in-place.

### NormiesMinter.sol / NormiesMinterV2.sol

Signature-verified minting contracts. A backend server signs `(imageData, traits, minter, maxMints, deadline)` using
EIP-191, and the contract verifies the signature on-chain. Supports single and batch minting with per-wallet mint
limits. V2 adds delegate.xyz v1 registry support alongside v2 for cold wallet delegation.

### NormiesRenderer.sol / V2 / V3

On-chain SVG rendering pipeline that evolved across three versions:

- **V1** — Animated noise pre-reveal, static SVG post-reveal
- **V2** — Static noise pre-reveal, improved SVG rendering
- **V3** — Post-reveal only, RLE-optimized SVG via `DynamicBufferLib`, adds Pixel Count numeric trait, HTML canvas
  `animation_url` for pixel-perfect rendering

### NormiesTraits.sol

Pure library mapping trait indices to human-readable names across 8 categories: Type, Gender, Age, Hair Style, Facial
Feature, Eyes, Expression, and Accessory.

## API Server

Off-chain API (`api-server/`) built with Hono + viem that reads token data directly from the Normies and NormiesStorage
contracts on Ethereum mainnet. Provides REST endpoints for individual token data:

- `GET /normie/:id/image.svg` — SVG render
- `GET /normie/:id/image.png` — PNG render (via resvg)
- `GET /normie/:id/traits` — decoded trait names (JSON)
- `GET /normie/:id/metadata` — full token metadata (JSON)
- `GET /normie/:id/pixels` — raw pixel string
- `GET /health` — health check

Includes LRU caching, rate limiting, and fallback RPC support. See `api-server/.env.example` for configuration.

```bash
cd api-server
pnpm install
pnpm dev
```

## Deployed Contracts (Ethereum Mainnet)

| Contract          | Address                                      |
| ----------------- | -------------------------------------------- |
| Normies           | `0x9Eb6E2025B64f340691e424b7fe7022fFDE12438` |
| NormiesStorage    | `0x1B976bAf51cF51F0e369C070d47FBc47A706e602` |
| NormiesRenderer   | `0xBe57fC4D0c729b8e8d33b638Dd441F57365e4c25` |
| NormiesRendererV2 | `0x7818f24d3239c945510e0a1a523dd9971812c6c0` |
| NormiesRendererV3 | `0x1af01b902256d77cf9499a14ef4e494897380b05` |
| NormiesMinter     | `0xC74994dD70FFb621CC514cE18a4F6F52124e296d` |
| NormiesMinterV2   | `0xc513272597d3022D77b3d7EEBA92cea5D7fb2808` |

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Bun](https://bun.sh)
- [pnpm](https://pnpm.io) (for api-server)

### Setup

```bash
bun install
```

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Lint

```bash
bun run lint
```

### Coverage

```bash
bun run test:coverage
```

## License

MIT
