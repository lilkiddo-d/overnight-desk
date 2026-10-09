"use client";

import { createContext, useCallback, useContext, useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { usePathname } from "next/navigation";
import { RiskModal } from "@/components/RiskModal";

const KEY = "overnight-desk:risk-ack";
/** Bump to force every user to re-acknowledge after a material change to the disclosure. */
export const RISK_VERSION = "2026-10-08";

type RiskCtx = { accepted: boolean; ready: boolean; open: () => void; accept: () => void };
const Ctx = createContext<RiskCtx>({ accepted: false, ready: false, open: () => {}, accept: () => {} });

export function RiskProvider({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const [accepted, setAccepted] = useState(false);
  const [ready, setReady] = useState(false);
  const [show, setShow] = useState(false);

  useEffect(() => {
    let ok = false;
    try {
      ok = window.localStorage.getItem(KEY) === RISK_VERSION;
    } catch {
      ok = false;
    }
    setAccepted(ok);
    setReady(true);
    // first visit: prompt, except on the disclosure / blocked pages themselves
    if (!ok && pathname !== "/risk" && pathname !== "/blocked") setShow(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const accept = useCallback(() => {
    try {
      window.localStorage.setItem(KEY, RISK_VERSION);
    } catch {
      // storage disabled: acceptance lasts for this session only
    }
    setAccepted(true);
    setShow(false);
  }, []);

  const open = useCallback(() => setShow(true), []);
  const value = useMemo(() => ({ accepted, ready, open, accept }), [accepted, ready, open, accept]);

  return (
    <Ctx.Provider value={value}>
      {children}
      {show && <RiskModal onAccept={accept} onClose={() => setShow(false)} />}
    </Ctx.Provider>
  );
}

export function useRisk(): RiskCtx {
  return useContext(Ctx);
}
