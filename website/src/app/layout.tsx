import type { Metadata } from "next";
import "./globals.css";

const siteUrl = process.env.NEXT_PUBLIC_SITE_URL;

export const metadata: Metadata = {
  ...(siteUrl ? { metadataBase: new URL(siteUrl) } : {}),
  title: "PetPaw — A little company for your Mac",
  description:
    "Meet PetPaw, your playful macOS desktop companion. Import a pet, share a little cuddle, and bring a little personality to your day.",
  icons: { icon: "/icon.png", apple: "/icon.png" },
  openGraph: {
    title: "PetPaw — A little pet. A lot of company.",
    description:
      "A playful desktop companion that makes your Mac feel a little more alive.",
    type: "website",
    ...(siteUrl
      ? {
          images: [
            {
              url: "/images/cozy-desktop.webp",
              width: 1536,
              height: 1024,
              alt: "An orange kitten keeping you company at your desk",
            },
          ],
        }
      : {}),
  },
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
