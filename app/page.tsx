import type { Metadata } from "next";
import { FlasherConsole } from "./FlasherConsole";

export const metadata: Metadata = {
  title: "VHOS Gateway Provisioner",
  description: "Backup, verify, flash, and recover WiCAN Pro VHOS gateway firmware.",
};

export default function Home() {
  return <FlasherConsole />;
}
