import type { Metadata } from "next";
import "./globals.css";

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || "https://pet.rxlab.app";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "PetPaw — A little company for your Mac",
  description:
    "Meet PetPaw, your playful macOS desktop companion. Import a pet, share a little cuddle, and bring a little personality to your day.",
  icons: { icon: "/icon.png", apple: "/icon.png" },
  openGraph: {
    title: "PetPaw — A little pet. A lot of company.",
    description:
      "A playful desktop companion that makes your Mac feel a little more alive.",
    type: "website",
    siteName: "PetPaw",
    url: "/",
  },
  twitter: { card: "summary_large_image" },
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
