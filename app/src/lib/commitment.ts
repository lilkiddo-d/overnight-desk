// Sealed-bid commitment helpers. Mirrors AuctionHouse.commitmentHash:
//   keccak256(abi.encode(owner, bookId, epoch, side, amount, collateral, rateBps, salt))
// The hash MUST be computed locally. Calling the contract's commitmentHash() over RPC would leak the sealed rate.
// This module only imports viem so it can be run directly by `node --test` (type stripping).
import { encodeAbiParameters, keccak256, bytesToHex, isAddress, isHex } from "viem";
import type { Address, Hex } from "viem";

export const SIDE_LEND = 0;
export const SIDE_BORROW = 1;
export type Side = 0 | 1;

export type CommitmentInput = {
  owner: Address;
  bookId: number;
  epoch: bigint;
  side: Side;
  amount: bigint;
  collateral: bigint; // 0 for lenders
  rateBps: number;
  salt: Hex;
};

const COMMITMENT_PARAMS = [
  { type: "address" },
  { type: "uint32" },
  { type: "uint64" },
  { type: "uint8" },
  { type: "uint256" },
  { type: "uint256" },
  { type: "uint32" },
  { type: "bytes32" },
] as const;

export function encodeCommitment(i: CommitmentInput): Hex {
  if (!isAddress(i.owner)) throw new Error("invalid owner");
  if (!isHex(i.salt) || i.salt.length !== 66) throw new Error("salt must be 32 bytes");
  if (!Number.isInteger(i.bookId) || i.bookId < 0 || i.bookId > 0xffffffff) throw new Error("invalid bookId");
  if (!Number.isInteger(i.rateBps) || i.rateBps < 0 || i.rateBps > 0xffffffff) throw new Error("invalid rate");
  return encodeAbiParameters(COMMITMENT_PARAMS, [
    i.owner,
    i.bookId,
    i.epoch,
    i.side,
    i.amount,
    i.collateral,
    i.rateBps,
    i.salt,
  ]);
}

export function commitmentHash(i: CommitmentInput): Hex {
  return keccak256(encodeCommitment(i));
}

/** 32 cryptographically random bytes from the platform CSPRNG. */
export function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  globalThis.crypto.getRandomValues(bytes);
  return bytesToHex(bytes);
}
