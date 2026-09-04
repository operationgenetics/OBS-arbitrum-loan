# Deploying ObscuraLoan to Arbitrum One

Two paths, same contract and the same preflight checks:

| | Use when |
|---|---|
| **`deploy.js`** | You hold the deployer key in an env var (CI, a server, a hardware-backed signer via RPC). |
| **`--qr`** | Scan a QR straight into MetaMask. Needs a free WalletConnect project ID. |
| **`index.html`** | You want to sign in **MetaMask** and never expose a private key to a script. |

Both refuse to broadcast until every preflight check passes.

---

## 0. Build first

```bash
forge build
node deploy/export-artifacts.js     # or: npm run build
```

`export-artifacts.js` copies the ABI and bytecode that forge just produced into
`deploy/artifacts/`. Both deploy paths read from there, so they can never drift
from `src/`.

---

## Path A — automated (`deploy.js`)

```bash
npm install                          # ethers v6

# Always dry-run first. Spends nothing, but runs every check and simulates
# the constructor against the live chain.
npm run deploy:dry

# Real deployment
PRIVATE_KEY=0xabc... npm run deploy
```

Environment:

| Variable | Default | Meaning |
|---|---|---|
| `PRIVATE_KEY` | — | Deployer key. Required to broadcast. |
| `ARB_RPC_URL` | `https://arb1.arbitrum.io/rpc` | RPC endpoint. |
| `OBS_TOKEN` | `0xa473…D7B0` | OBS address. Defaults to the contract's own constant. |
| `AI_ORACLE` | `0x0` | AI scoring signer. `0x0` disables AI scoring entirely. |

It will not broadcast if the chain is wrong, OBS has no code, OBS is not a
working ERC-20, the deployer has no ETH, or the constructor reverts in
simulation. Add `--yes` to skip the interactive prompt (for CI only).

After deploying it re-reads the contract and verifies OBS wiring, oracle
wiring, the 150% top tier, the 500–850 score band and an empty pool, then
writes a record to `deploy/deployments/`.

---

## Path B — MetaMask (`index.html`)

```bash
open deploy/index.html          # macOS
xdg-open deploy/index.html      # Linux
```

The page:
1. Connects MetaMask.
2. **Adds Arbitrum One to the wallet if it is missing**, and switches to it
   (`wallet_addEthereumChain` / `wallet_switchEthereumChain`).
3. Runs the same preflight checks and simulates the constructor.
4. Deploys, then verifies the on-chain state and prints the Arbiscan link,
   the `forge verify-contract` command, and a deployment record.

The Deploy button stays disabled until preflight is clean, and it asks you to
type `DEPLOY` before requesting a signature.

### Arbitrum One network parameters

If you would rather add the network by hand:

| Field | Value |
|---|---|
| Network name | Arbitrum One |
| RPC URL | `https://arb1.arbitrum.io/rpc` |
| Chain ID | `42161` |
| Currency symbol | `ETH` |
| Block explorer | `https://arbiscan.io` |

---

## After deployment

1. **Verify the source on Arbiscan** — the exact command is printed for you.
   Unverified lending contracts should not attract deposits.
2. **Seed liquidity.** `approve()` OBS to the pool, then `stake()`. Until
   somebody stakes, `availableLiquidity()` is zero and nobody can borrow.
3. **Run a liquidation keeper.** `liquidate(borrower)` is permissionless and
   pays a 5% bounty, but staker funds are only protected as fast as somebody
   calls it. Do not assume the market will show up on day one.
4. **The reserve has to grow before 150% LTV unlocks.** The `reserve-coverage`
   gate requires the insurance reserve to cover 25% of aggregate unsecured
   exposure, and the reserve is funded by 5% of interest. This is intended:
   undercollateralised lending switches itself on only once the pool has earned
   a buffer. Use `loanEligibility(borrower, amount, collateral)` to see which
   gate is currently binding.

## Deploying somewhere else first

Arbitrum Sepolia (chain `421614`, RPC `https://sepolia-rollup.arbitrum.io/rpc`)
needs its own OBS deployment — the mainnet address holds no code there, so the
constructor will revert with `TokenNotDeployed`. Deploy a test ERC-20, then pass
it via `OBS_TOKEN`.


---

## Path C — scan a QR into MetaMask (`--qr`)

```bash
WALLETCONNECT_PROJECT_ID=<id> npm run deploy:qr
```

Get the ID free at <https://dashboard.reown.com> (sign in, create a project,
copy the Project ID). It takes about a minute and is needed once.

The script runs the full preflight, opens a WalletConnect channel, prints the
QR, and waits. You scan with MetaMask's scanner, approve the connection, then
approve the deployment. Your key never leaves the phone; this machine only
builds the transaction and watches for the receipt.

### Why a project ID is needed at all

A QR code holds at most 2,953 bytes and the deployment init code is ~17.7 KB —
about 6x over. So the QR cannot carry the transaction; it carries a short
pairing URI, and the transaction crosses a **relay**. WalletConnect's relay
requires a project ID.

### A QR is not proof of a connection

`--qr` **refuses to print a QR until the relay has actually opened the
channel.** This is not defensive padding: MetaMask's own Node SDK
(`@metamask/sdk`, still available as `--qr-mm`) happily produces a valid-looking
`metamask.app.link` QR while never contacting its relay at all — measured at
zero packets over 15 seconds of 50 ms polling. Scanning such a code does
nothing: the phone reaches the relay and finds nobody listening, with no error
on either side.

If the channel does not come up, you get a clear failure and no QR, rather than
a code that silently goes nowhere.

### No signup at all

`npm run deploy:qr:web` serves the MetaMask page locally and QR-encodes its
URL. You open that link in MetaMask's in-app browser instead of scanning into
the app directly. Same contract, same preflight — it just involves tapping a
link rather than a pure in-app scan.
