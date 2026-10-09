import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { Wallet } from "ethers";
import { privateKeyToAccount, type Account } from "viem/accounts";
import type { Address } from "viem";

export type SignerMode =
  | { kind: "keystore"; account: Account }
  | { kind: "unlocked"; address: Address } // local anvil only: node signs with its own dev account
  | { kind: "dry-run"; address: Address }; // simulate only, never sends

/**
 * Resolves the keeper signer. Production signs ONLY with the Foundry keystore `overnightdesk-keeper`
 * (created by `cast wallet import overnightdesk-keeper --interactive`). The key is decrypted in memory and is never
 * logged, written to disk, or returned to the caller as a string.
 */
export async function resolveSigner(env: NodeJS.ProcessEnv, chainId: number): Promise<SignerMode> {
  if (env.KEEPER_DRY_RUN === "1") {
    return { kind: "dry-run", address: (env.KEEPER_ADDRESS ?? "0x000000000000000000000000000000000000dEaD") as Address };
  }
  if (env.KEEPER_UNLOCKED_ADDRESS) {
    if (chainId !== 31337) throw new Error("KEEPER_UNLOCKED_ADDRESS is only allowed on a local anvil fork (chain 31337)");
    return { kind: "unlocked", address: env.KEEPER_UNLOCKED_ADDRESS as Address };
  }
  const name = env.KEEPER_ACCOUNT ?? "overnightdesk-keeper";
  const dir = env.FOUNDRY_KEYSTORE_DIR ?? join(homedir(), ".foundry", "keystores");
  const path = join(dir, name);
  if (!existsSync(path)) {
    throw new Error(`Keystore ${path} not found. Run: cast wallet import ${name} --interactive`);
  }
  const password = env.KEEPER_PASSWORD_FILE
    ? readFileSync(env.KEEPER_PASSWORD_FILE, "utf8").trim()
    : await promptHidden(`Password for keystore '${name}': `);
  const wallet = await Wallet.fromEncryptedJson(readFileSync(path, "utf8"), password);
  const account = privateKeyToAccount(wallet.privateKey as `0x${string}`);
  return { kind: "keystore", account };
}

function promptHidden(question: string): Promise<string> {
  return new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true });
    const out = rl as unknown as { _writeToOutput: (s: string) => void; output: NodeJS.WriteStream };
    let asked = false;
    out._writeToOutput = (s: string) => {
      if (!asked) {
        out.output.write(s);
        asked = true;
      }
    };
    rl.question(question, (answer) => {
      rl.close();
      process.stdout.write("\n");
      resolve(answer);
    });
  });
}
