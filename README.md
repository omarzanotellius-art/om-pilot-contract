# om-pilot-contract

A learning project: one Solidity smart contract that keeps a hash-anchored audit trail of operations-and-maintenance (O&M) records for a single solar asset, and releases stablecoin payments for inspections and routine repairs under fixed, written rules.

It is a learning exercise, built in the open to show asset owners and operators how a smart contract can work in day-to-day operations. It is **not** a security token, and it has nothing to do with tokenising or selling an asset.

> **Status:** work in progress — Stage 0 (setup). Nothing here is finished or deployed.

## Read this first

- **Not audited.** No security review of any kind. Do not use this code with real money.
- **Testnet only.** Runs on a local simulated chain and on the Polygon Amoy test network, with valueless test tokens.
- **Not a product or service.** It is not offered to anyone.
- **Fictional names.** Jupiter Ridge Solar, Aldermont Energy Holdings, Tavistone Asset Services, and the people in the examples are invented. Any resemblance to real companies or people is unintended.

## Setup

Tested with Node.js 22.

```bash
npm install
npm run build   # compile
npm test        # run all tests
```

### Why the compiler comes from npm

The Solidity compiler (version 0.8.37) is taken from the npm `solc` package, pinned in `package.json`, instead of being downloaded by Hardhat at build time. Everyone who clones this repository therefore compiles with exactly the same compiler file. See `hardhat.config.ts`.

### About the `npm install` security warnings

`npm install` reports warnings in development tools. They were reviewed and deliberately left in place:

- **2 high — `tmp`, via `solc`.** `tmp` is used by the `solc` package's command-line tool. This project never runs that tool: Hardhat loads only the compiler file itself. npm's suggested fix would downgrade the compiler to 0.8.36, which is not worth doing to silence a warning in unused code.
- **11 low — `elliptic`, via Hardhat's contract-verification plugin.** These come from older ethers.js packages that the plugin depends on. npm's suggested fix would install an incompatible, previous-generation plugin. It is Hardhat's dependency to update.

None of these affect the contract itself: nothing from these packages is deployed.

## License

Copyright © 2026 OnToken, LLC. All rights reserved.

An open-source license is to be decided before this repository is made public. Until a license file is added, no permission to use, copy or modify this code is granted.
