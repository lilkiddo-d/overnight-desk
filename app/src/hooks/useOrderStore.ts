"use client";

import { useSyncExternalStore } from "react";
import { getOrders, getServerOrders, subscribe } from "@/lib/orderStore";
import type { StoredOrder } from "@/lib/orderStore";

/** Reactive view of the locally stored order secrets. */
export function useStoredOrders(): StoredOrder[] {
  return useSyncExternalStore(subscribe, getOrders, getServerOrders);
}
