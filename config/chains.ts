/**
 * Chain configuration for Overnight Desk.
 *
 * Every address here was taken from an official source (linked inline) and checked on-chain with `cast`
 * (code present, symbol/description matches) on 2026-10-08. Do not add an address without a source link.
 *
 * The protocol deploy parameters (stablecoin, collateral, oracle feeds, haircuts) live in
 * contracts/config/deploy.<chainId>.json, which Deploy.s.sol reads. This file re-exports that data, so
 * there is a single source of truth.
 */
import deploy4663 from "../contracts/config/deploy.4663.json";

export type ChainInfo = {
  id: number;
  name: string;
  nativeCurrency: { name: string; symbol: string; decimals: number };
  rpcUrls: { public: string[]; providers: string[] };
  explorer: { url: string; apiUrl: string; verifier: "blockscout" };
  contracts: Record<string, `0x${string}`>;
  sources: Record<string, string>;
};

/** Robinhood Chain mainnet: an Arbitrum Orbit L2. Source: https://docs.robinhood.com/chain/connecting */
export const robinhoodMainnet: ChainInfo = {
  id: 4663,
  name: "Robinhood Chain",
  // Gas token is ETH. Source: https://docs.robinhood.com/chain/connecting
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    // The public RPC is rate-limited and "not for production use" (per docs). Use a provider for the keeper and frontend.
    public: ["https://rpc.mainnet.chain.robinhood.com"],
    providers: [
      "https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}",
      "https://robinhood-mainnet.core.chainstack.com/{ENDPOINT}",
      "https://{ENDPOINT}.robinhood-mainnet.quiknode.pro/{TOKEN}",
    ],
  },
  explorer: {
    url: "https://robinhoodchain.blockscout.com",
    // Source: https://docs.robinhood.com/chain/deploy-smart-contracts (forge --verifier blockscout)
    apiUrl: "https://robinhoodchain.blockscout.com/api/",
    verifier: "blockscout",
  },
  contracts: {
    // Source: https://www.multicall3.com (canonical deployment; code verified on-chain)
    multicall3: "0xcA11bde05977b3631167028862bE2a173976CA11",
    // Source: https://docs.robinhood.com/chain/protocol-contracts
    permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
    // WETH. Source: https://docs.robinhood.com/chain/contracts
    weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
    // USDG (Paxos Global Dollar), 6 decimals. Sources: https://docs.robinhood.com/chain/contracts ,
    // https://docs.paxos.com/guides/stablecoin/usdg/mainnet
    usdg: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
    // Chainlink Data Streams verifier proxy (not used yet). Source: https://docs.robinhood.com/chain/data-streams
    dataStreamsVerifier: "0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7",
  },
  sources: {
    chain: "https://docs.robinhood.com/chain/connecting",
    verification: "https://docs.robinhood.com/chain/deploy-smart-contracts",
    stockTokens: "https://docs.robinhood.com/chain/contracts (live list: https://api.robinhood.com/rhj/assets)",
    stockTokenBehaviour: "https://docs.robinhood.com/chain/stock-tokens",
    oracles: "https://docs.robinhood.com/chain/oracles-and-price-feeds",
    chainlinkFeeds: "https://docs.chain.link/data-feeds/tokenized-equity-feeds/robinhood",
    chainlinkFeedJson: "https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json",
  },
};

/** Robinhood Chain testnet. Source: https://docs.robinhood.com/chain/connecting */
export const robinhoodTestnet: ChainInfo = {
  id: 46630,
  name: "Robinhood Chain Testnet",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { public: ["https://rpc.testnet.chain.robinhood.com"], providers: ["https://robinhood-testnet.g.alchemy.com/v2/{API_KEY}"] },
  explorer: {
    url: "https://explorer.testnet.chain.robinhood.com",
    apiUrl: "https://explorer.testnet.chain.robinhood.com/api/",
    verifier: "blockscout",
  },
  contracts: {
    // USDG testnet. Source: https://docs.paxos.com/guides/stablecoin/usdg/testnet
    usdg: "0x7E955252E15c84f5768B83c41a71F9eba181802F",
    // Source: https://docs.robinhood.com/chain/protocol-contracts
    weth: "0x7943e237c7F95DA44E0301572D358911207852Fa",
  },
  sources: {
    chain: "https://docs.robinhood.com/chain/connecting",
    faucet: "https://faucet.testnet.chain.robinhood.com",
    // GAP: no official testnet stock-token list and no testnet Chainlink feeds were found. See DECISIONS.md.
  },
};

/**
 * Collateral universe + Chainlink feeds (mainnet). Stock tokens are 18-decimal ERC-20s (beacon proxies with an
 * issuer blocklist/pause, and ERC-8056 scaled UI amounts). Chainlink equity feeds use 8 decimals, have a 24h heartbeat,
 * update 24/5, and already include the token multiplier.
 */
export const mainnetDeployConfig = deploy4663;

/**
 * Known gaps on Robinhood Chain (2026-10-08), handled by swappable adapters:
 *  - No Chainlink L2 sequencer-uptime feed: OracleAdapter.setSequencerUptimeFeed() is left unset; set it via the Timelock when one ships.
 *  - No second independent oracle (Pyth, RedStone and Chronicle are not deployed): the deviation cross-check is disabled.
 *    PushPriceFeed can be deployed as a secondary feed if an operator relays a second source.
 *  - No native Circle USDC: USDG is the loan stablecoin.
 */
export const knownGaps = [
  "sequencer-uptime-feed",
  "secondary-oracle",
  "native-usdc",
  "testnet-stock-tokens",
] as const;

/** Local anvil fork of mainnet (chain id overridden to 31337 so wallets never confuse it with mainnet). */
export const localFork = { id: 31337, rpcUrl: "http://127.0.0.1:8571", forkOf: 4663 } as const;
