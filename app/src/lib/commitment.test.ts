// Run with: pnpm --filter app test   (node --test, Node >= 22.18 strips TypeScript types natively)
import { test } from "node:test";
import assert from "node:assert/strict";
import { commitmentHash, encodeCommitment, randomSalt, SIDE_BORROW, SIDE_LEND } from "./commitment.ts";

// Reference vectors. The hashes were derived outside viem:
//  - the ABI encoding was built by hand (8 static words, each left-padded to 32 bytes, as Solidity abi.encode does),
//  - keccak256 was computed by anvil's web3_sha3 RPC (alloy implementation),
//  - vector 1 was additionally confirmed against the deployed AuctionHouse.commitmentHash() on the local fork
//    (eth_call with this public test vector only; real orders are never hashed over RPC).
// Equivalent cast command for vector 1:
//   cast keccak $(cast abi-encode "f(address,uint32,uint64,uint8,uint256,uint256,uint32,bytes32)" \
//     0x0000000000000000000000000000000000000001 1 2 0 1000000000 0 500 0x00..aa)
const word = (n: bigint | number) => BigInt(n).toString(16).padStart(64, "0");

test("vector 1 (lend) matches Solidity abi.encode + keccak256", () => {
  const input = {
    owner: "0x0000000000000000000000000000000000000001",
    bookId: 1,
    epoch: 2n,
    side: SIDE_LEND,
    amount: 1_000_000_000n,
    collateral: 0n,
    rateBps: 500,
    salt: "0x00000000000000000000000000000000000000000000000000000000000000aa",
  } as const;
  const expectedEncoding = "0x" + [1, 1, 2, 0, 1_000_000_000, 0, 500, 0xaa].map(word).join("");
  assert.equal(encodeCommitment(input), expectedEncoding);
  assert.equal(commitmentHash(input), "0xfb6965f0a448acbb1dc62b49a823c89c89f1d5e8d49ef013698e802c598e5df9");
});

test("vector 2 (borrow, checksummed owner, 18-dec collateral) matches", () => {
  const input = {
    owner: "0x00000000000000000000000000000000DeaDBeef",
    bookId: 7,
    epoch: 12345n,
    side: SIDE_BORROW,
    amount: 2_500_000_000n,
    collateral: 10n ** 18n,
    rateBps: 875,
    salt: "0x1111111111111111111111111111111111111111111111111111111111111111",
  } as const;
  assert.equal(commitmentHash(input), "0x1434b27f4d3b816f856d4c1dda0994b41e0e1a3d73d8af8cf709e747c624041c");
});

test("any field change changes the commitment", () => {
  const base = {
    owner: "0x0000000000000000000000000000000000000001",
    bookId: 1,
    epoch: 2n,
    side: SIDE_LEND,
    amount: 1_000_000_000n,
    collateral: 0n,
    rateBps: 500,
    salt: "0x00000000000000000000000000000000000000000000000000000000000000aa",
  } as const;
  const h = commitmentHash(base);
  assert.notEqual(commitmentHash({ ...base, rateBps: 501 }), h);
  assert.notEqual(commitmentHash({ ...base, epoch: 3n }), h);
  assert.notEqual(commitmentHash({ ...base, side: SIDE_BORROW }), h);
});

test("randomSalt returns 32 random bytes", () => {
  const a = randomSalt();
  const b = randomSalt();
  assert.match(a, /^0x[0-9a-f]{64}$/);
  assert.notEqual(a, b);
});

test("rejects malformed salt", () => {
  assert.throws(() =>
    commitmentHash({
      owner: "0x0000000000000000000000000000000000000001",
      bookId: 1,
      epoch: 2n,
      side: SIDE_LEND,
      amount: 1n,
      collateral: 0n,
      rateBps: 1,
      salt: "0x1234",
    }),
  );
});
