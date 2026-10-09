"use client";

import { useRisk } from "@/providers/RiskProvider";

export function RiskAcceptButton() {
  const { accepted, ready, open } = useRisk();
  if (!ready) return null;
  return (
    <div className="card flex flex-wrap items-center justify-between gap-3">
      <p className="text-sm text-muted">
        {accepted ? "You have acknowledged this disclosure in this browser." : "Trading actions stay disabled until you acknowledge these risks."}
      </p>
      {!accepted && (
        <button type="button" className="btn-primary" onClick={open}>
          Acknowledge risks
        </button>
      )}
    </div>
  );
}
