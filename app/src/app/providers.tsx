"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { useState } from "react";
import type { ReactNode } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import { WagmiProvider } from "wagmi";
import { supportedChains, wagmiConfig } from "@/config/wagmi";
import { DeploymentProvider } from "@/providers/DeploymentProvider";
import { RiskProvider } from "@/providers/RiskProvider";

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(
    () =>
      new QueryClient({
        defaultOptions: { queries: { staleTime: 4_000, refetchOnWindowFocus: false, retry: 1 } },
      }),
  );
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider
          theme={darkTheme({ accentColor: "#22c55e", accentColorForeground: "#04130a", borderRadius: "medium" })}
          initialChain={supportedChains[0]}
          appInfo={{ appName: "Overnight Desk", learnMoreUrl: "/risk" }}
        >
          <DeploymentProvider>
            <RiskProvider>{children}</RiskProvider>
          </DeploymentProvider>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
