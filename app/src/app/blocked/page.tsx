import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = { title: "Not available in your region" };

export default function BlockedPage() {
  return (
    <div className="mx-auto max-w-xl py-10">
      <div className="card space-y-3 text-center">
        <h1 className="text-xl font-semibold">Overnight Desk is not available in your region</h1>
        <p className="text-sm text-muted">
          Based on your location, access to this interface is restricted. Overnight Desk is not offered to US persons or
          in restricted or sanctioned jurisdictions, and the tokenized stocks used as collateral are not offered there
          either.
        </p>
        <p className="text-sm text-muted">
          If you already have open positions, they remain on-chain and can be managed directly through the smart
          contracts. Please do not attempt to circumvent this restriction.
        </p>
        <Link href="/risk" className="text-sm text-accent underline">
          Read the risk disclosure
        </Link>
      </div>
    </div>
  );
}
