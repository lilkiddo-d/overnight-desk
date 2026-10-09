"use client";

import { DeploymentGate } from "@/components/DeploymentGate";
import { BorrowerRepos } from "@/components/repos/BorrowerRepos";
import { Claims } from "@/components/repos/Claims";
import { LenderNotes } from "@/components/repos/LenderNotes";
import { LiquidationAuctions } from "@/components/repos/LiquidationAuctions";

export default function ReposPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Positions</h1>
        <p className="mt-1 text-sm text-muted">
          Your open repos (as borrower), your repo notes (as lender), claimable balances and live liquidation auctions.
        </p>
      </div>
      <DeploymentGate>
        <div className="space-y-6">
          <BorrowerRepos />
          <Claims />
          <LenderNotes />
          <LiquidationAuctions />
        </div>
      </DeploymentGate>
    </div>
  );
}
