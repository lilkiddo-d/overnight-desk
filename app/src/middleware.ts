import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

// NEXT_PUBLIC_GEOBLOCK_COUNTRIES is inlined at build time: comma-separated ISO-3166 alpha-2 codes, empty => no geoblock.
const BLOCKED = new Set(
  (process.env.NEXT_PUBLIC_GEOBLOCK_COUNTRIES || "")
    .split(",")
    .map((s) => s.trim().toUpperCase())
    .filter((s) => /^[A-Z]{2}$/.test(s)),
);

const ALWAYS_ALLOWED = ["/blocked", "/risk"];

export function middleware(req: NextRequest) {
  if (BLOCKED.size === 0) return NextResponse.next();
  const { pathname } = req.nextUrl;
  if (ALWAYS_ALLOWED.some((p) => pathname === p || pathname.startsWith(p + "/"))) return NextResponse.next();
  const country = (req.headers.get("x-vercel-ip-country") || "").toUpperCase();
  if (country && BLOCKED.has(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    url.search = "";
    return NextResponse.redirect(url, 307);
  }
  return NextResponse.next();
}

export const config = {
  // skip Next internals, static assets and the deployment files
  matcher: ["/((?!_next/static|_next/image|favicon.ico|icon.svg|robots.txt|deployments/|.*\\.(?:png|jpg|jpeg|gif|svg|ico|webp|json|txt|css|js|map)$).*)"],
};
