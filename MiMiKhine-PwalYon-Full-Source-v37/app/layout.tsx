import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL("https://shwe-war-pwal-yon.hlanhtet25.chatgpt.site"),
  title: "မီမီခိုင် ပွဲရုံ — လုပ်ငန်းစီမံခန့်ခွဲမှု",
  description:
    "တောင်သူ၊ Mobile ချိန်တွယ်မှု၊ ပဲ/ငရုတ်ငွေရှင်း၊ နေ့စဉ်ဈေးကွက်ပေါက်ဈေး၊ လစဉ်အတက်အကျ Report၊ စိုက်ထုတ်၊ ကုန်ပစ္စည်းအရောင်းနှင့် ဂိုဒေါင်စနစ်",
  openGraph: {
    title: "MI MI KHINE PWAL YON — လုပ်ငန်းစီမံခန့်ခွဲမှု",
    description: "တောင်သူ · ချိန်တွယ် · နေ့စဉ်ပေါက်ဈေး · လစဉ်/နှစ်စဉ် Report · ဂိုဒေါင်",
    type: "website",
    images: [{ url: "/og.png", width: 1536, height: 1024 }],
  },
  twitter: {
    card: "summary_large_image",
    title: "MI MI KHINE PWAL YON — လုပ်ငန်းစီမံခန့်ခွဲမှု",
    description: "တောင်သူ · ချိန်တွယ် · နေ့စဉ်ပေါက်ဈေး · လစဉ်/နှစ်စဉ် Report · ဂိုဒေါင်",
    images: ["/og.png"],
  },
  icons: {
    icon: "/favicon.svg",
    shortcut: "/favicon.svg",
  },
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="my">
      <body>{children}</body>
    </html>
  );
}
