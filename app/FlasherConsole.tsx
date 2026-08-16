"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ESPLoader as ESPLoaderType, Transport as TransportType } from "esptool-js";

type ReleaseManifest = {
  schemaVersion: "1.0.0";
  release: string;
  channel: "development" | "stable";
  publishedAt: string;
  chipFamily: "ESP32-S3";
  hardwareFamily: "WiCAN-OBD-PRO";
  hardwareRevision: string;
  upstreamTag: string;
  sourceCommit: string;
  firmwareCommit: string;
  espIdfVersion: string;
  artifact: {
    url: string;
    address: number;
    byteCount: number;
    sha256: string;
  };
};

type Stage = "idle" | "connecting" | "connected" | "backing-up" | "ready" | "flashing" | "complete" | "error";

const MANIFEST_URL = "/firmware/manifest.json";
const SUPPORTED_CHIP = "ESP32-S3";

function formatBytes(value: number | null) {
  if (value === null) return "—";
  if (value >= 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
  if (value >= 1024) return `${(value / 1024).toFixed(1)} KB`;
  return `${value} B`;
}

function asHex(bytes: ArrayBuffer) {
  return Array.from(new Uint8Array(bytes), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256(bytes: Uint8Array) {
  return asHex(await crypto.subtle.digest("SHA-256", bytes));
}

function bytesToBinaryString(bytes: Uint8Array) {
  const chunkSize = 32_768;
  let result = "";
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    result += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return result;
}

function timestamp() {
  return new Date().toLocaleTimeString([], { hour12: false });
}

export function FlasherConsole() {
  const [manifest, setManifest] = useState<ReleaseManifest | null>(null);
  const [manifestError, setManifestError] = useState<string | null>(null);
  const [stage, setStage] = useState<Stage>("idle");
  const [chip, setChip] = useState<string | null>(null);
  const [flashBytes, setFlashBytes] = useState<number | null>(null);
  const [backupHash, setBackupHash] = useState<string | null>(null);
  const [backupComplete, setBackupComplete] = useState(false);
  const [hardwareConfirmed, setHardwareConfirmed] = useState(false);
  const [recoveryFile, setRecoveryFile] = useState<File | null>(null);
  const [progress, setProgress] = useState(0);
  const [logs, setLogs] = useState<string[]>([
    `${timestamp()}  Provisioner initialized. No device access has been requested.`,
  ]);
  const loaderRef = useRef<ESPLoaderType | null>(null);
  const transportRef = useRef<TransportType | null>(null);

  const serialSupported = typeof navigator !== "undefined" && "serial" in navigator;
  const secureContext = typeof window !== "undefined" && window.isSecureContext;
  const chipMatches = chip?.toUpperCase().includes(SUPPORTED_CHIP) ?? false;
  const releaseVerified = Boolean(manifest && !manifestError);

  const appendLog = useCallback((line: string) => {
    setLogs((current) => [...current.slice(-39), `${timestamp()}  ${line}`]);
  }, []);

  useEffect(() => {
    let cancelled = false;
    fetch(MANIFEST_URL, { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) throw new Error(`release manifest unavailable (${response.status})`);
        return (await response.json()) as ReleaseManifest;
      })
      .then((value) => {
        if (cancelled) return;
        if (value.schemaVersion !== "1.0.0" || value.chipFamily !== SUPPORTED_CHIP) {
          throw new Error("release manifest target is not supported");
        }
        setManifest(value);
        appendLog(`Loaded ${value.release} manifest for ${value.hardwareFamily}.`);
      })
      .catch((error: unknown) => {
        if (cancelled) return;
        const message = error instanceof Error ? error.message : "release manifest unavailable";
        setManifestError(message);
        appendLog(`Install blocked: ${message}.`);
      });
    return () => {
      cancelled = true;
    };
  }, [appendLog]);

  const terminal = useMemo(
    () => ({
      clean: () => setLogs([]),
      write: (value: string) => appendLog(value.trim()),
      writeLine: (value: string) => appendLog(value.trim()),
    }),
    [appendLog],
  );

  async function connect() {
    if (!serialSupported || !secureContext) return;
    setStage("connecting");
    setProgress(0);
    try {
      const { ESPLoader, Transport } = await import("esptool-js");
      const port = await navigator.serial.requestPort();
      const transport = new Transport(port, false, true);
      const loader = new ESPLoader({
        transport,
        baudrate: 460800,
        romBaudrate: 115200,
        terminal,
      });
      const detected = await loader.main();
      const capacity = await loader.getFlashSize();
      loaderRef.current = loader;
      transportRef.current = transport;
      setChip(detected);
      setFlashBytes(capacity);
      setStage(detected.toUpperCase().includes(SUPPORTED_CHIP) ? "connected" : "error");
      appendLog(
        detected.toUpperCase().includes(SUPPORTED_CHIP)
          ? `Hardware gate passed: ${detected}, ${formatBytes(capacity)} flash.`
          : `Hardware gate failed: detected ${detected}; required ${SUPPORTED_CHIP}.`,
      );
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "unable to open the serial device";
      setStage("error");
      appendLog(`Connection failed: ${message}`);
    }
  }

  async function disconnect() {
    try {
      await transportRef.current?.disconnect();
    } finally {
      loaderRef.current = null;
      transportRef.current = null;
      setChip(null);
      setFlashBytes(null);
      setBackupComplete(false);
      setBackupHash(null);
      setStage("idle");
      appendLog("Serial session closed.");
    }
  }

  async function backup() {
    const loader = loaderRef.current;
    if (!loader || !chipMatches || !flashBytes) return;
    setStage("backing-up");
    setProgress(0);
    try {
      appendLog(`Reading ${formatBytes(flashBytes)} factory/recovery image from address 0x00000000.`);
      const data = await loader.readFlash(0, flashBytes, (_packet, completed, total) => {
        setProgress(Math.round((completed / total) * 100));
      });
      const digest = await sha256(data);
      const blob = new Blob([data], { type: "application/octet-stream" });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `wican-pro-factory-backup-${new Date().toISOString().replaceAll(":", "-")}-${digest.slice(0, 12)}.bin`;
      link.click();
      URL.revokeObjectURL(url);
      setBackupHash(digest);
      setBackupComplete(true);
      setProgress(100);
      setStage("ready");
      appendLog(`Backup complete. SHA-256 ${digest}. Keep this file off-device.`);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "flash read failed";
      setStage("error");
      appendLog(`Backup failed: ${message}`);
    }
  }

  async function writeImage(bytes: Uint8Array, label: string, expectedHash?: string) {
    const loader = loaderRef.current;
    if (!loader || !chipMatches) return;
    setStage("flashing");
    setProgress(0);
    try {
      const digest = await sha256(bytes);
      if (expectedHash && digest !== expectedHash.toLowerCase()) {
        throw new Error(`SHA-256 mismatch; expected ${expectedHash}, received ${digest}`);
      }
      appendLog(`${label} verified (${formatBytes(bytes.byteLength)}, SHA-256 ${digest}).`);
      await loader.writeFlash({
        fileArray: [{ data: bytesToBinaryString(bytes), address: 0 }],
        flashSize: "keep",
        flashMode: "keep",
        flashFreq: "keep",
        eraseAll: false,
        compress: true,
        reportProgress: (_index, written, total) => {
          setProgress(Math.round((written / total) * 100));
        },
      });
      setProgress(100);
      await loader.after("hard_reset");
      setStage("complete");
      appendLog(`${label} written and verified by the ESP ROM loader. Device reset requested.`);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "flash write failed";
      setStage("error");
      appendLog(`${label} failed: ${message}`);
    }
  }

  async function installRelease() {
    if (!manifest) return;
    try {
      appendLog(`Downloading ${manifest.release} from the published release manifest.`);
      const response = await fetch(manifest.artifact.url, { cache: "no-store" });
      if (!response.ok) throw new Error(`firmware download failed (${response.status})`);
      const bytes = new Uint8Array(await response.arrayBuffer());
      if (bytes.byteLength !== manifest.artifact.byteCount) {
        throw new Error(
          `firmware length mismatch; expected ${manifest.artifact.byteCount}, received ${bytes.byteLength}`,
        );
      }
      await writeImage(bytes, `VHOS ${manifest.release}`, manifest.artifact.sha256);
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : "firmware download failed";
      setStage("error");
      appendLog(`Install blocked: ${message}`);
    }
  }

  async function restoreBackup() {
    if (!recoveryFile || !flashBytes) return;
    if (recoveryFile.size !== flashBytes) {
      setStage("error");
      appendLog(
        `Recovery blocked: backup is ${formatBytes(recoveryFile.size)} but connected flash is ${formatBytes(flashBytes)}.`,
      );
      return;
    }
    await writeImage(new Uint8Array(await recoveryFile.arrayBuffer()), "Factory backup recovery");
  }

  const installReady =
    stage === "ready" && chipMatches && backupComplete && hardwareConfirmed && releaseVerified;

  return (
    <main>
      <header className="topbar">
        <a className="brand" href="#top" aria-label="VHOS provisioner home">
          <span className="brandMark" aria-hidden="true">V</span>
          <span>VHOS / GATEWAY PROVISIONER</span>
        </a>
        <nav aria-label="Project links">
          <a href="https://github.com/IsaiahDupree/4runner-vehicle-health-os">PROJECT</a>
          <a href="https://github.com/IsaiahDupree/4runner-vhos-firmware">SOURCE</a>
          <span className="labLabel">DEVELOPMENT</span>
        </nav>
      </header>

      <section className="hero" id="top">
        <div className="eyebrow">ESP32-S3 · WICAN PRO · USB SERIAL</div>
        <h1>Flash with a way back.</h1>
        <p className="heroCopy">
          A backup-first installer for the 4Runner Vehicle Health OS gateway. It identifies the chip,
          preserves the full factory flash, verifies the release checksum, then writes the merged image.
        </p>
        <div className="heroActions">
          <button className="primary" onClick={connect} disabled={!serialSupported || !secureContext || stage !== "idle"}>
            CONNECT WICAN PRO
          </button>
          {chip && <button className="secondary" onClick={disconnect}>DISCONNECT</button>}
          <span className="supportNote">
            {serialSupported && secureContext ? "Chrome or Edge desktop · HTTPS active" : "Requires desktop Chrome/Edge over HTTPS"}
          </span>
        </div>
      </section>

      <section className="statusRail" aria-label="Provisioning gates">
        <Status index="01" label="Browser" value={serialSupported && secureContext ? "READY" : "BLOCKED"} good={serialSupported && secureContext} />
        <Status index="02" label="ESP target" value={chip ?? "NOT CONNECTED"} good={chipMatches} />
        <Status index="03" label="Factory backup" value={backupComplete ? "SAVED" : "REQUIRED"} good={backupComplete} />
        <Status index="04" label="Release" value={manifest?.release ?? "UNAVAILABLE"} good={releaseVerified} />
      </section>

      <section className="workspace">
        <div className="mainColumn">
          <div className="sectionHeading">
            <span>PROVISIONING SEQUENCE</span>
            <span>{stage.replace("-", " ").toUpperCase()}</span>
          </div>

          <article className="step">
            <div className="stepNumber">01</div>
            <div>
              <h2>Identify the gateway</h2>
              <p>Connect USB-C data while the WiCAN Pro is powered as specified by MeatPi. The tool enters the ROM loader and rejects non-ESP32-S3 targets.</p>
              <dl>
                <div><dt>Detected chip</dt><dd>{chip ?? "—"}</dd></div>
                <div><dt>Flash capacity</dt><dd>{formatBytes(flashBytes)}</dd></div>
                <div><dt>Required board</dt><dd>MeatPi MP-WICAN-PRO; verify board revision physically</dd></div>
              </dl>
            </div>
          </article>

          <article className="step">
            <div className="stepNumber">02</div>
            <div>
              <h2>Save the recovery image</h2>
              <p>Read every byte of flash before changing it. The downloaded file and SHA-256 are the device-specific route back to the current factory state.</p>
              <button className="action" onClick={backup} disabled={!chipMatches || stage === "backing-up" || stage === "flashing"}>
                {stage === "backing-up" ? `READING FLASH ${progress}%` : backupComplete ? "BACKUP SAVED" : "BACK UP FULL FLASH"}
              </button>
              {backupHash && <code className="hash">SHA-256 {backupHash}</code>}
            </div>
          </article>

          <article className="step">
            <div className="stepNumber">03</div>
            <div>
              <h2>Verify and install VHOS</h2>
              <p>The browser checks byte count and SHA-256 from the published manifest before the ESP loader writes address 0. Existing flash parameters are preserved.</p>
              <label className="confirm">
                <input type="checkbox" checked={hardwareConfirmed} onChange={(event) => setHardwareConfirmed(event.target.checked)} />
                <span>I confirm this is a WiCAN Pro ESP32-S3 and the factory backup is stored safely.</span>
              </label>
              <button className="install" onClick={installRelease} disabled={!installReady}>
                {stage === "flashing" ? `WRITING ${progress}%` : "INSTALL VERIFIED VHOS IMAGE"}
              </button>
              {!releaseVerified && <p className="blockReason">Install locked: {manifestError ?? "release verification is still running"}.</p>}
            </div>
          </article>
        </div>

        <aside>
          <div className="sectionHeading"><span>RELEASE RECORD</span></div>
          <dl className="releaseRecord">
            <div><dt>Version</dt><dd>{manifest?.release ?? "—"}</dd></div>
            <div><dt>Channel</dt><dd>{manifest?.channel ?? "—"}</dd></div>
            <div><dt>Hardware</dt><dd>{manifest?.hardwareFamily ?? "WiCAN-OBD-PRO"}</dd></div>
            <div><dt>ESP-IDF</dt><dd>{manifest?.espIdfVersion ?? "—"}</dd></div>
            <div><dt>Upstream</dt><dd>{manifest?.upstreamTag ?? "v4.50p"}</dd></div>
            <div><dt>Image</dt><dd>{formatBytes(manifest?.artifact.byteCount ?? null)}</dd></div>
          </dl>
          <div className="checksum">
            <span>RELEASE SHA-256</span>
            <code>{manifest?.artifact.sha256 ?? "No verified artifact published"}</code>
          </div>

          <div className="terminal" aria-live="polite">
            <div className="terminalTitle"><span>SESSION LOG</span><span>{logs.length.toString().padStart(2, "0")}</span></div>
            <pre>{logs.join("\n")}</pre>
          </div>

          <div className="recovery">
            <h2>Recovery</h2>
            <p>Select a full-flash backup created by this tool. The file must exactly match the connected flash capacity.</p>
            <input type="file" accept=".bin,application/octet-stream" onChange={(event) => setRecoveryFile(event.target.files?.[0] ?? null)} />
            <button className="secondary wide" onClick={restoreBackup} disabled={!recoveryFile || !chipMatches || stage === "flashing"}>
              RESTORE SELECTED BACKUP
            </button>
          </div>
        </aside>
      </section>

      <footer>
        <span>NO VEHICLE-BUS TRANSMIT CONTROLS</span>
        <span>USB FIRST-FLASH · SIGNED WI-FI OTA ACTIVATION PENDING</span>
        <span>GPL-3.0 FIRMWARE SOURCE PUBLISHED</span>
      </footer>
    </main>
  );
}

function Status({ index, label, value, good }: { index: string; label: string; value: string; good: boolean }) {
  return (
    <div className="statusItem">
      <span className="statusIndex">{index}</span>
      <span className={`dot ${good ? "good" : ""}`} aria-hidden="true" />
      <span className="statusLabel">{label}</span>
      <strong>{value}</strong>
    </div>
  );
}
