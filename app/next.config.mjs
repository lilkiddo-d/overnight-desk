/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  poweredByHeader: false,
  webpack: (config) => {
    // Optional peer deps pulled in by WalletConnect / MetaMask SDK that are not needed in the browser.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    config.resolve.fallback = {
      ...(config.resolve.fallback ?? {}),
      "@react-native-async-storage/async-storage": false,
    };
    // wagmi's Base Account connector -> @coinbase/cdp-sdk imports optional x402 payment packages that are not
    // installed (and not used by this app). Stub them out (prefix aliases also cover their subpaths).
    config.resolve.alias = {
      ...(config.resolve.alias ?? {}),
      "@x402/core": false,
      "@x402/evm": false,
      "@x402/svm": false,
    };
    return config;
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
        ],
      },
      {
        // deployment files are rewritten by the deploy script; never serve a stale copy
        source: "/deployments/:file*",
        headers: [{ key: "Cache-Control", value: "no-store, max-age=0" }],
      },
    ];
  },
};

export default nextConfig;
