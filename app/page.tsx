import type { Metadata } from "next";
import { FlasherConsole } from "./FlasherConsole";

export const metadata: Metadata = {
  title: "VHOS Gateway Provisioner",
  description: "Select, back up, verify, flash, and recover supported VHOS ESP32 gateways.",
};

export default function Home() {
  return <FlasherConsole />;
}
