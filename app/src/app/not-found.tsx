import Link from "next/link";

export default function NotFound() {
  return (
    <div className="mx-auto max-w-md py-16 text-center">
      <h1 className="text-xl font-semibold">Page not found</h1>
      <Link href="/" className="mt-4 inline-block text-sm text-accent underline">
        Back to the dashboard
      </Link>
    </div>
  );
}
