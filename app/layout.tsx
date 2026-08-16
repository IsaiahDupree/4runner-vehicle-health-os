import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import { headers } from "next/headers";
import "./globals.css";

const geistSans = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });
const geistMono = Geist_Mono({ variable: "--font-geist-mono", subsets: ["latin"] });

export async function generateMetadata(): Promise<Metadata> {
  const requestHeaders = await headers();
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host") ?? "localhost:3000";
  const protocol = requestHeaders.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const origin = new URL(`${protocol}://${host.split(",")[0].trim()}`);
  const image = new URL("/og.png", origin);
  const description = "Backup-first, hardware-gated ESP32 firmware installer and recovery tool for VHOS gateways.";

  return {
    metadataBase: origin,
    title: { default: "VHOS Gateway Provisioner", template: "%s · VHOS" },
    description,
    icons: { icon: "/favicon.svg", shortcut: "/favicon.svg" },
    openGraph: {
      title: "VHOS Gateway Provisioner",
      description,
      type: "website",
      url: origin,
      images: [{ url: image, width: 1200, height: 630, alt: "VHOS gateway provisioner hardware targets" }],
    },
    twitter: {
      card: "summary_large_image",
      title: "VHOS Gateway Provisioner",
      description,
      images: [image],
    },
  };
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${geistSans.variable} ${geistMono.variable}`}>{children}</body>
    </html>
  );
}
