"use client";

import { DeploymentGate } from "@/components/DeploymentGate";
import { OrderForm } from "@/components/trade/OrderForm";
import { MyOrders } from "@/components/trade/MyOrders";

export default function TradePage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Trade</h1>
        <p className="mt-1 text-sm text-muted">
          Lend or borrow at a sealed rate. Amounts are public and escrowed; only your rate limit is hidden until you
          reveal it. Everyone who matches gets the same clearing rate.
        </p>
      </div>
      <DeploymentGate>
        <div className="grid gap-6 lg:grid-cols-5">
          <div className="lg:col-span-2">
            <OrderForm />
          </div>
          <div className="lg:col-span-3">
            <MyOrders />
          </div>
        </div>
      </DeploymentGate>
    </div>
  );
}
