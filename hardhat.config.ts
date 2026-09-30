import path from "node:path";
import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import { configVariable, defineConfig } from "hardhat/config";

export default defineConfig({
  plugins: [hardhatToolboxViemPlugin],
  solidity: {
    // Compiler: Solidity 0.8.37, taken from the npm "solc" package (pinned in
    // package.json) instead of Hardhat's usual download. Everyone who clones
    // this repository compiles with exactly the same compiler file.
    // The path must be absolute, so it is resolved from the project folder.
    version: "0.8.37",
    path: path.resolve("node_modules/solc/soljson.js"),
    // The optimiser rewrites the compiled code to be smaller and cheaper to run,
    // without changing what it does (decision 75). 200 "runs" is the common default.
    // All tests run against this optimised code, so what is tested is what is deployed.
    settings: {
      optimizer: { enabled: true, runs: 200 },
    },
  },
  networks: {
    // Polygon Amoy test network (Stage 3 demo). Secrets are referred to by NAME only;
    // their values live in Hardhat's password-protected keystore (decision 84),
    // never in this file or the repository. Account 0 = Owner (Dana), 1 = Provider (Luis).
    amoy: {
      type: "http",
      chainType: "generic",
      chainId: 80002,
      url: configVariable("AMOY_RPC_URL"),
      accounts: [configVariable("AMOY_OWNER_PRIVATE_KEY"), configVariable("AMOY_PROVIDER_PRIVATE_KEY")],
    },
  },
});
