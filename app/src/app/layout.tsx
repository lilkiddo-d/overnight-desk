import type { Metadata, Viewport } from "next";
import Link from "next/link";
import type { ReactNode } from "react";
import "./globals.css";
import { Providers } from "./providers";
import { Header } from "@/components/Header";
import { NetworkGuard } from "@/components/NetworkGuard";

export const metadata: Metadata = {
  title: { default: "Overnight Desk", template: "%s · Overnight Desk" },
  description: "On-chain repo market: fixed-term, fixed-rate loans backed by tokenized stocks, cleared by sealed-bid auctions.",
};

export const viewport: Viewport = {
  themeColor: "#0b0e11",
  width: "device-width",
  initialScale: 1,
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" className="dark">
      <body className="min-h-screen bg-bg text-fg antialiased">
        <Providers>
          <Header />
          <NetworkGuard />
          <main className="mx-auto max-w-6xl px-4 py-6">{children}</main>
          <footer className="mx-auto max-w-6xl px-4 pb-10 pt-4 text-xs text-muted">
            <p>
              Overnight Desk is experimental, non-custodial software. Not investment advice. Not available to US persons
              or in restricted jurisdictions.{" "}
              <Link href="/risk" className="underline">
                Risk disclosure
              </Link>
            </p>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
