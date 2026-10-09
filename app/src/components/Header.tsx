"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { useStakingEnabled } from "@/hooks/useStaking";

const BASE_LINKS = [
  { href: "/", label: "Dashboard" },
  { href: "/trade", label: "Trade" },
  { href: "/auctions", label: "Auctions" },
  { href: "/repos", label: "Positions" },
  { href: "/notes", label: "Notes" },
  { href: "/risk", label: "Risk" },
];

function Logo() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" aria-hidden="true">
      <circle cx="12" cy="12" r="10" fill="none" stroke="currentColor" strokeWidth="2" />
      <path d="M15.5 6.5a6 6 0 1 0 0 11 7 7 0 0 1 0-11z" fill="currentColor" />
    </svg>
  );
}

export function Header() {
  const pathname = usePathname();
  const staking = useStakingEnabled();
  const [open, setOpen] = useState(false);
  const links = staking ? [...BASE_LINKS.slice(0, 5), { href: "/stake", label: "Stake" }, BASE_LINKS[5]] : BASE_LINKS;
  const isActive = (href: string) => (href === "/" ? pathname === "/" : pathname.startsWith(href));

  return (
    <header className="sticky top-0 z-40 border-b border-line bg-bg/90 backdrop-blur">
      <div className="mx-auto flex h-14 max-w-6xl items-center gap-3 px-4">
        <Link href="/" className="flex shrink-0 items-center gap-2 font-semibold text-accent">
          <Logo />
          <span className="text-fg">Overnight Desk</span>
        </Link>
        <nav className="ml-4 hidden items-center gap-1 md:flex">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              className={`rounded-md px-2.5 py-1.5 text-sm ${isActive(l.href) ? "bg-panel2 text-fg" : "text-muted hover:text-fg"}`}
            >
              {l.label}
            </Link>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-2">
          <ConnectButton chainStatus="icon" accountStatus={{ smallScreen: "avatar", largeScreen: "full" }} showBalance={false} />
          <button
            type="button"
            className="rounded-md border border-line p-2 md:hidden"
            aria-label="Menu"
            aria-expanded={open}
            onClick={() => setOpen((o) => !o)}
          >
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
              <path d="M2 4h12M2 8h12M2 12h12" stroke="currentColor" strokeWidth="1.5" />
            </svg>
          </button>
        </div>
      </div>
      {open && (
        <nav className="border-t border-line px-4 py-2 md:hidden">
          {links.map((l) => (
            <Link
              key={l.href}
              href={l.href}
              onClick={() => setOpen(false)}
              className={`block rounded-md px-2 py-2 text-sm ${isActive(l.href) ? "bg-panel2 text-fg" : "text-muted"}`}
            >
              {l.label}
            </Link>
          ))}
        </nav>
      )}
    </header>
  );
}
