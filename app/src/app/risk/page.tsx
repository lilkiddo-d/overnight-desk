import type { Metadata } from "next";
import type { ReactNode } from "react";
import { RiskAcceptButton } from "./RiskAcceptButton";

export const metadata: Metadata = { title: "Risk disclosure" };

function Section({ id, title, children }: { id: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="card scroll-mt-20 space-y-2 text-sm leading-relaxed">
      <h2 className="text-base font-semibold">{title}</h2>
      {children}
    </section>
  );
}

export default function RiskPage() {
  return (
    <div className="mx-auto max-w-3xl space-y-4">
      <div>
        <h1 className="text-2xl font-semibold">Risk disclosure</h1>
        <p className="mt-1 text-sm text-muted">
          Read this in full before using Overnight Desk. Using the protocol can result in the loss of all funds you
          deposit, lend or post as collateral.
        </p>
      </div>

      <Section id="advice" title="Not investment advice">
        <p>
          Overnight Desk is open-source, non-custodial software that lets users interact with smart contracts. Nothing on
          this site is investment, legal, tax or financial advice, a recommendation, or an offer or solicitation to buy or
          sell any security or financial product. Rates shown are results of past auctions and are not forecasts. You are
          solely responsible for your decisions and for complying with the laws that apply to you.
        </p>
      </Section>

      <Section id="eligibility" title="Eligibility and restricted jurisdictions">
        <p>
          Overnight Desk is <strong>not offered to US persons</strong> or to anyone located in, incorporated in, or a
          resident of a sanctioned or otherwise restricted jurisdiction. The tokenized stocks used as collateral on this
          chain are themselves not offered to US persons and are restricted in some other jurisdictions under their
          issuer&apos;s terms; consult the issuer&apos;s documentation (
          <a className="underline" href="https://docs.robinhood.com/rhj" target="_blank" rel="noreferrer noopener">
            docs.robinhood.com/rhj
          </a>
          ) for the current list of eligible jurisdictions and eligibility requirements before acquiring or using them.
          Overnight Desk is independent and is not affiliated with or endorsed by the token issuer or the chain operator. Access from restricted locations may be blocked. Using
          a VPN or other means to circumvent restrictions is prohibited.
        </p>
      </Section>

      <Section id="contracts" title="Smart contract risk">
        <p>
          The protocol is a set of smart contracts that may contain bugs or design flaws despite testing and review.
          Exploits can result in permanent loss of funds. Transactions are irreversible. The interface may display
          incorrect information because of RPC, indexing or software errors; always verify transactions in your wallet.
        </p>
      </Section>

      <Section id="liquidation" title="Margin calls and liquidation by Dutch auction">
        <p>
          Borrowers must keep debt below the collateral value after the maintenance haircut. If it is not, the repo enters
          a margin call with a grace period to repay or add collateral. If the call is not cured in time, if the debt
          exceeds the collateral value net of the liquidation penalty, or if a repo is unpaid after maturity plus its
          grace period, the collateral is seized and sold by a <strong>descending-price (Dutch) auction</strong> that
          starts above and can end well below the oracle price. Borrowers pay a liquidation penalty and may receive back
          only the collateral left after the debt and penalty are covered. Liquidations are permissionless and can be
          triggered by anyone.
        </p>
      </Section>

      <Section id="gap" title="Gap risk at market open (overnight and weekends)">
        <p>
          Tokenized stocks trade on-chain around the clock, but the reference equity markets and their price feeds do
          not. Prices can move sharply between the close and the next open, over weekends and holidays, or on news. A
          position that looks safe on a stale price can be immediately liquidatable when fresh prices arrive. Lenders bear
          bad-debt risk if collateral proceeds do not cover the debt.
        </p>
      </Section>

      <Section id="oracle" title="Oracle risk">
        <p>
          Collateral is valued using Chainlink price feeds through an on-chain adapter. Equity feeds update on a 24-hour
          heartbeat outside trading hours and can be stale, wrong, delayed or discontinued. When a price is stale beyond
          its configured limit, actions that need a price (new borrowing, clearing that checks margin, liquidations)
          halt until a fresh price arrives. There is currently no secondary oracle cross-check and no L2 sequencer
          uptime feed on this chain.
        </p>
      </Section>

      <Section id="issuer" title="Stock-token issuer risk">
        <p>
          Collateral tokens are issued by a third party that can pause transfers, block-list addresses, change token
          behaviour (for example corporate-action multipliers) or redeem tokens. A pause or block-list affecting the
          protocol contracts or your address could prevent repayments, collateral withdrawals, liquidations or
          settlements, and could cause losses for both borrowers and lenders. Tokenized stocks are not the underlying
          shares and may not carry shareholder rights.
        </p>
      </Section>

      <Section id="stablecoin" title="Stablecoin (USDG) risk">
        <p>
          Loans are denominated in USDG, a third-party stablecoin. It can lose its peg, be frozen, paused or block-listed
          by its issuer, or suffer from the issuer&apos;s insolvency. All lending, interest and repayment amounts are paid
          in that stablecoin, not in US dollars.
        </p>
      </Section>

      <Section id="sealed" title="Sealed-bid mechanics and the no-reveal penalty">
        <p>
          Orders are placed in two steps. During the commit phase you escrow your amount (lenders: stablecoin, borrowers:
          collateral) with a hash of your rate. During the reveal phase you must reveal the rate and the random salt.
          The rate and salt exist only in your browser storage and in any backup you download.{" "}
          <strong>
            If you lose them or miss the reveal window, the order cannot be revealed and 1% of its escrow (the current
            no-reveal penalty) is forfeited
          </strong>{" "}
          when it is settled. Everyone who matches in an auction receives the single uniform clearing rate, which may be
          better than your limit. Borrow bids that fail the initial-margin check at clearing are excluded.
        </p>
      </Section>

      <Section id="keepers" title="Keeper liveness">
        <p>
          Clearing auctions, rolling repos and poking margin are permissionless actions usually performed by automated
          keepers. If no one clears an auction in its clearing window, every order in it becomes fully refundable at
          expiry, but your funds are idle until then. If keepers are offline, margin calls and liquidations may be
          delayed, which can increase losses. Auto-roll is best effort: if a roll does not fill, the borrower must repay by
          maturity plus the grace period.
        </p>
      </Section>

      <Section id="early" title="Early repayment and note returns">
        <p>
          Borrowers may repay at any time and pay interest only up to the repayment time. Notes therefore redeem for a
          pro-rata share of what the series actually collected, which can be <strong>less than the headline rate</strong>{" "}
          if borrowers repay early, and less than principal if liquidations leave bad debt. Notes become redeemable only
          after every repo in the series is closed.
        </p>
      </Section>

      <Section id="liquidity" title="Note market liquidity">
        <p>
          The note market is a simple fixed-price listing board. There may be no buyers or sellers at any given time, and
          prices can differ substantially from the expected value at maturity. Implied yields shown are simple estimates
          that assume full repayment at the series rate on the maturity date.
        </p>
      </Section>

      <Section id="governance" title="Governance, guardian pause and compliance">
        <p>
          Protocol parameters (haircuts, fees, oracles, enabled books) are controlled by a governance timelock with a
          48-hour delay; changes can still affect open positions after the delay. A guardian key can pause new orders,
          clearing, listings and some withdrawals at any time; repayments, collateral top-ups, reveals, settlements and
          claims are designed to remain available. A compliance allowlist can be enabled, after which only allowlisted
          addresses can place orders or trade notes (existing positions can still be unwound).
        </p>
      </Section>

      <Section id="tax" title="Other risks">
        <p>
          Network congestion, high gas prices, RPC outages, wallet bugs, phishing, lost keys and regulatory changes can
          all cause losses. You may owe taxes on your activity. Robinhood Chain is a third-party network; its operation,
          finality and fees are outside the control of Overnight Desk.
        </p>
      </Section>

      <RiskAcceptButton />
    </div>
  );
}
