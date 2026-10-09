/**
 * Overnight Desk keeper.
 *
 * Every tick it:
 *   1. clears every book whose auction is in its clearing window (skips empty books),
 *   2. submits auto-roll bids for opted-in repos maturing before the next auction (commit phase only),
 *   3. pokes repos that need a margin action (margin call, cure, liquidation, overdue), in bounded batches,
 *   4. restarts Dutch auctions that reached their floor unsold,
 *   5. distributes accumulated fees once per day.
 * Every write is simulated first (eth_call) and only sent if the simulation succeeds.
 * All keeper actions are permissionless, so several keepers (or users) can run in parallel safely.
 *
 * Env: see scripts/.env.example
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient,
  createWalletClient,
  defineChain,
  http,
  type Address,
  type Abi,
  type PublicClient,
  type WalletClient,
} from "viem";
import {
  AuctionHouseAbi,
  MarketClockAbi,
  TermRegistryAbi,
  RepoLockerAbi,
  MarginEngineAbi,
  LiquidatorAbi,
  FeeCollectorAbi,
} from "./abi/index.js";
import { resolveSigner, type SignerMode } from "./signer.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const PHASE = { Pending: 0, Commit: 1, Reveal: 2, Clearing: 3, Expired: 4 } as const;
const STATUS = { None: 0, Active: 1, MarginCall: 2, Liquidating: 3, Closed: 4 } as const;
const POKE_BATCH = 100;

type Deployment = Record<string, string> & { chainId: number };

function log(msg: string, extra?: unknown) {
  const line = `[${new Date().toISOString()}] ${msg}`;
  console.log(extra === undefined ? line : `${line} ${JSON.stringify(extra, (_, v) => (typeof v === "bigint" ? v.toString() : v))}`);
}

class Keeper {
  private lastDistribute = 0;

  constructor(
    private pub: PublicClient,
    private wallet: WalletClient | null,
    private signer: SignerMode,
    private d: Deployment,
  ) {}

  private get from(): Address {
    return this.signer.kind === "keystore" ? this.signer.account.address : this.signer.address;
  }

  /** Simulate, then send (unless dry-run). Returns true if the call would succeed. */
  private async send(address: string, abi: Abi, functionName: string, args: readonly unknown[], label: string) {
    try {
      const { request } = await this.pub.simulateContract({
        address: address as Address,
        abi,
        functionName,
        args,
        account: this.signer.kind === "keystore" ? this.signer.account : this.from,
      } as never);
      if (this.signer.kind === "dry-run" || !this.wallet) {
        log(`DRY-RUN would send ${label}`);
        return true;
      }
      const hash = await this.wallet.writeContract(request as never);
      const receipt = await this.pub.waitForTransactionReceipt({ hash });
      log(`sent ${label}`, { hash, status: receipt.status, gasUsed: receipt.gasUsed });
      return receipt.status === "success";
    } catch (e) {
      log(`skip ${label}: ${(e as Error).message.split("\n")[0]}`);
      return false;
    }
  }

  private read<T>(address: string, abi: Abi, functionName: string, args: readonly unknown[] = []): Promise<T> {
    return this.pub.readContract({ address: address as Address, abi, functionName, args } as never) as Promise<T>;
  }

  async tick() {
    const now = BigInt(Math.floor(Date.now() / 1000));
    const block = await this.pub.getBlock();
    const cur = await this.read<bigint>(this.d.MarketClock, MarketClockAbi, "currentEpoch");
    const bookCount = await this.read<number>(this.d.TermRegistry, TermRegistryAbi, "bookCount");
    log(`tick epoch=${cur} books=${bookCount} block=${block.number} chainTime=${block.timestamp} wall=${now}`);

    await this.clearAuctions(cur, bookCount);
    await this.submitRolls(cur);
    await this.pokeRepos();
    await this.restartLiquidations(block.timestamp);
    if (Date.now() - this.lastDistribute > 24 * 3600 * 1000) {
      await this.send(this.d.FeeCollector, FeeCollectorAbi, "distribute", [], "FeeCollector.distribute");
      this.lastDistribute = Date.now();
    }
  }

  private async clearAuctions(cur: bigint, bookCount: number) {
    for (const epoch of cur > 0n ? [cur - 1n, cur] : [cur]) {
      const phase = await this.read<number>(this.d.MarketClock, MarketClockAbi, "phase", [epoch]);
      if (phase !== PHASE.Clearing) continue;
      for (let b = 0; b < bookCount; b++) {
        const res = await this.read<{ cleared: boolean }>(this.d.AuctionHouse, AuctionHouseAbi, "getResult", [b, epoch]);
        if (res.cleared) continue;
        const [lends, borrows] = await this.read<[bigint[], bigint[]]>(this.d.AuctionHouse, AuctionHouseAbi, "bookOrders", [b, epoch]);
        if (lends.length === 0 && borrows.length === 0) continue;
        await this.send(this.d.AuctionHouse, AuctionHouseAbi, "clear", [b, epoch], `clear(book=${b}, epoch=${epoch})`);
      }
    }
  }

  private async openRepos() {
    const next = await this.read<bigint>(this.d.RepoLocker, RepoLockerAbi, "nextRepoId");
    const ids: bigint[] = [];
    for (let i = 1n; i < next; i++) ids.push(i);
    const repos = await this.pub.multicall({
      contracts: ids.map((id) => ({ address: this.d.RepoLocker as Address, abi: RepoLockerAbi, functionName: "getRepo", args: [id] })),
      allowFailure: true,
    } as never);
    return ids
      .map((id, i) => ({ id, r: (repos[i] as { result?: Record<string, unknown> }).result }))
      .filter((x): x is { id: bigint; r: Record<string, unknown> } => !!x.r && (x.r.status === STATUS.Active || x.r.status === STATUS.MarginCall));
  }

  private async submitRolls(cur: bigint) {
    const phase = await this.read<number>(this.d.MarketClock, MarketClockAbi, "phase", [cur]);
    if (phase !== PHASE.Commit) return;
    for (const { id, r } of await this.openRepos()) {
      if (!r.autoRoll || r.rolling || r.status !== STATUS.Active) continue;
      await this.send(this.d.AuctionHouse, AuctionHouseAbi, "submitRepoRoll", [id], `submitRepoRoll(${id})`);
    }
  }

  private async pokeRepos() {
    const open = await this.openRepos();
    if (open.length === 0) return;
    const block = await this.pub.getBlock();
    const needs: bigint[] = [];
    for (const { id, r } of open) {
      try {
        const [debt, , maint] = await this.read<[bigint, bigint, bigint, bigint]>(this.d.MarginEngine, MarginEngineAbi, "health", [id]);
        const unhealthy = debt > maint;
        const curable = r.status === STATUS.MarginCall && !unhealthy;
        const callExpired = r.status === STATUS.MarginCall && block.timestamp >= (r.marginCallDeadline as bigint);
        const overdue = block.timestamp > (r.maturity as bigint);
        if ((unhealthy && r.status === STATUS.Active) || curable || callExpired || overdue || unhealthy) needs.push(id);
      } catch (e) {
        log(`health(${id}) failed (oracle stale?): ${(e as Error).message.split("\n")[0]}`);
      }
    }
    for (let i = 0; i < needs.length; i += POKE_BATCH) {
      const batch = needs.slice(i, i + POKE_BATCH);
      await this.send(this.d.MarginEngine, MarginEngineAbi, "pokeBatch", [batch], `pokeBatch(${batch.join(",")})`);
    }
  }

  private async restartLiquidations(chainTime: bigint) {
    const next = await this.read<bigint>(this.d.Liquidator, LiquidatorAbi, "nextAuctionId");
    const duration = await this.read<number>(this.d.Liquidator, LiquidatorAbi, "duration");
    for (let i = 1n; i < next; i++) {
      const a = await this.read<{ active: boolean; startTime: bigint }>(this.d.Liquidator, LiquidatorAbi, "getAuction", [i]);
      if (a.active && chainTime >= a.startTime + BigInt(duration)) {
        await this.send(this.d.Liquidator, LiquidatorAbi, "restart", [i], `Liquidator.restart(${i})`);
      }
    }
  }
}

async function main() {
  const env = process.env;
  const rpcUrl = env.KEEPER_RPC_URL ?? "http://127.0.0.1:8571";
  const probe = createPublicClient({ transport: http(rpcUrl) });
  const chainId = await probe.getChainId();
  const deploymentPath = env.KEEPER_DEPLOYMENT ?? join(root, "deployments", `${chainId}.json`);
  const d = JSON.parse(readFileSync(deploymentPath, "utf8")) as Deployment;
  const chain = defineChain({
    id: chainId,
    name: chainId === 4663 ? "Robinhood Chain" : `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpcUrl] } },
    contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
  });
  const pub = createPublicClient({ chain, transport: http(rpcUrl) }) as PublicClient;
  const signer = await resolveSigner(env, chainId);
  const wallet =
    signer.kind === "dry-run"
      ? null
      : createWalletClient({ chain, transport: http(rpcUrl), account: signer.kind === "keystore" ? signer.account : signer.address });
  log(`keeper up chain=${chainId} signer=${signer.kind} from=${signer.kind === "keystore" ? signer.account.address : signer.address}`);

  const keeper = new Keeper(pub, wallet as WalletClient | null, signer, d);
  const once = process.argv.includes("--once");
  const intervalMs = Number(env.KEEPER_INTERVAL_SECONDS ?? "60") * 1000;
  for (;;) {
    try {
      await keeper.tick();
    } catch (e) {
      log(`tick failed: ${(e as Error).message.split("\n")[0]}`);
    }
    if (once) break;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
