"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { ESPLoader as ESPLoaderType, Transport as TransportType } from "esptool-js";

type ReleaseManifest = {
  schemaVersion: "1.0.0";
  release: string;
  channel: "development" | "stable";
  publishedAt: string;
  chipFamily: "ESP32-S3" | "ESP32";
  hardwareFamily: "WiCAN-OBD-PRO" | "MRDIY-CAN-SHIELD";
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

type TargetId = "mrdiy-esp32-v13" | "wican-pro-esp32s3";

type ProvisioningTarget = {
  id: TargetId;
  label: string;
  shortLabel: string;
  chipFamily: ReleaseManifest["chipFamily"];
  manifestUrl: string;
  baudrate: number;
  connection: string;
  requiredBoard: string;
  confirmation: string;
  backupPrefix: string;
};

type Stage = "idle" | "connecting" | "connected" | "backing-up" | "ready" | "flashing" | "complete" | "error";

const TARGETS: ProvisioningTarget[] = [
  {
    id: "mrdiy-esp32-v13",
    label: "Classic ESP32 + MrDIY CAN Shield v1.3+",
    shortLabel: "MRDIY ESP32",
    chipFamily: "ESP32",
    manifestUrl: "/firmware/manifest-mrdiy-esp32-v13.json",
    baudrate: 230400,
    connection: "Connect the ESP32 DevKit USB data port. The shield pinout must be v1.3+.",
    requiredBoard: "ESP32-D0WDQ6 + MrDIY CAN Shield v1.3+; RX GPIO 4 / TX GPIO 5",
    confirmation: "I confirm this is a classic ESP32 with MrDIY CAN Shield v1.3+ and the full-flash backup is stored safely.",
    backupPrefix: "mrdiy-esp32-v13-factory-backup",
  },
  {
    id: "wican-pro-esp32s3",
    label: "ESP32-S3 + MeatPi WiCAN Pro",
    shortLabel: "WICAN PRO",
    chipFamily: "ESP32-S3",
    manifestUrl: "/firmware/manifest-wican-pro-esp32s3.json",
    baudrate: 460800,
    connection: "Connect USB-C data while the WiCAN Pro is powered as specified by MeatPi.",
    requiredBoard: "MeatPi MP-WICAN-PRO ESP32-S3; verify the board revision physically",
    confirmation: "I confirm this is a WiCAN Pro ESP32-S3 and the full-flash backup is stored safely.",
    backupPrefix: "wican-pro-factory-backup",
  },
];

function matchesTarget(chip: string | null, target: ProvisioningTarget | null) {
  if (!chip || !target) return false;
  const normalized = chip.toUpperCase();
  if (target.chipFamily === "ESP32-S3") return normalized.includes("ESP32-S3");
  return normalized.includes("ESP32") && !normalized.includes("ESP32-S");
}

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
  const [selectedTargetId, setSelectedTargetId] = useState<TargetId | null>(null);
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
  const selectedTarget = TARGETS.find((target) => target.id === selectedTargetId) ?? null;
  const chipMatches = matchesTarget(chip, selectedTarget);
  const releaseVerified = Boolean(manifest && !manifestError);

  const appendLog = useCallback((line: string) => {
    setLogs((current) => [...current.slice(-39), `${timestamp()}  ${line}`]);
  }, []);

  useEffect(() => {
    let cancelled = false;
    const target = TARGETS.find((candidate) => candidate.id === selectedTargetId);
    if (!target) return;
    fetch(target.manifestUrl, { cache: "no-store" })
      .then(async (response) => {
        if (!response.ok) throw new Error(`release manifest unavailable (${response.status})`);
        return (await response.json()) as ReleaseManifest;
      })
      .then((value) => {
        if (cancelled) return;
        if (value.schemaVersion !== "1.0.0" || value.chipFamily !== target.chipFamily) {
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
  }, [appendLog, selectedTargetId]);

  const terminal = useMemo(
    () => ({
      clean: () => setLogs([]),
      write: (value: string) => appendLog(value.trim()),
      writeLine: (value: string) => appendLog(value.trim()),
    }),
    [appendLog],
  );

  function selectTarget(targetId: TargetId) {
    setSelectedTargetId(targetId);
    setManifest(null);
    setManifestError(null);
    setHardwareConfirmed(false);
    setBackupComplete(false);
    setBackupHash(null);
    setRecoveryFile(null);
    setProgress(0);
    appendLog(`Selected ${TARGETS.find((target) => target.id === targetId)?.label}.`);
  }

  async function connect() {
    if (!serialSupported || !secureContext || !selectedTarget) return;
    setStage("connecting");
    setProgress(0);
    try {
      const { ESPLoader, Transport } = await import("esptool-js");
      const port = await navigator.serial.requestPort();
      const transport = new Transport(port, false, true);
      const loader = new ESPLoader({
        transport,
        baudrate: selectedTarget.baudrate,
        romBaudrate: 115200,
        terminal,
      });
      const detected = await loader.main();
      const capacity = await loader.getFlashSize();
      loaderRef.current = loader;
      transportRef.current = transport;
      setChip(detected);
      setFlashBytes(capacity);
      const detectedMatches = matchesTarget(detected, selectedTarget);
      setStage(detectedMatches ? "connected" : "error");
      appendLog(
        detectedMatches
          ? `Hardware gate passed: ${detected}, ${formatBytes(capacity)} flash.`
          : `Hardware gate failed: detected ${detected}; selected target requires ${selectedTarget.chipFamily}.`,
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
      setHardwareConfirmed(false);
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
      link.download = `${selectedTarget?.backupPrefix ?? "esp32-factory-backup"}-${new Date().toISOString().replaceAll(":", "-")}-${digest.slice(0, 12)}.bin`;
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
        <div className="eyebrow">ESP32 · ESP32-S3 · BACKUP-FIRST USB SERIAL</div>
        <h1>Flash with a way back.</h1>
        <p className="heroCopy">
          A hardware-gated installer for the 4Runner Vehicle Health OS gateway. Choose the exact board,
          preserve its full factory flash, verify the release checksum, then write the matching image.
        </p>
        <div className="heroActions">
          <button className="primary" onClick={connect} disabled={!serialSupported || !secureContext || !selectedTarget || stage !== "idle"}>
            {selectedTarget ? `CONNECT ${selectedTarget.shortLabel}` : "SELECT HARDWARE BELOW"}
          </button>
          {chip && <button className="secondary" onClick={disconnect}>DISCONNECT</button>}
          <span className="supportNote">
            {serialSupported && secureContext ? "Chrome or Edge desktop · HTTPS active" : "Requires desktop Chrome/Edge over HTTPS"}
          </span>
        </div>
      </section>

      <section className="targetPicker" aria-labelledby="target-heading">
        <div>
          <span className="targetIndex">HARDWARE GATE</span>
          <h2 id="target-heading">Select the board in your hand</h2>
          <p>The detected chip must match this selection before backup, install, or recovery unlocks.</p>
        </div>
        <div className="targetGrid">
          {TARGETS.map((target) => {
            const selected = selectedTargetId === target.id;
            return (
              <button
                key={target.id}
                type="button"
                className={`targetCard ${selected ? "selected" : ""}`}
                aria-pressed={selected}
                disabled={stage !== "idle"}
                onClick={() => selectTarget(target.id)}
              >
                <span>{target.chipFamily}</span>
                <strong>{target.label}</strong>
                <small>{target.requiredBoard}</small>
              </button>
            );
          })}
        </div>
      </section>

      <section className="statusRail" aria-label="Provisioning gates">
        <Status index="01" label="Browser" value={serialSupported && secureContext ? "READY" : "BLOCKED"} good={serialSupported && secureContext} />
        <Status index="02" label="ESP target" value={chip ?? selectedTarget?.chipFamily ?? "SELECT TARGET"} good={chipMatches} />
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
              <p>{selectedTarget?.connection ?? "Select the exact hardware target above before connecting a serial device."} The ROM loader rejects a chip that does not match the selection.</p>
              <dl>
                <div><dt>Detected chip</dt><dd>{chip ?? "—"}</dd></div>
                <div><dt>Flash capacity</dt><dd>{formatBytes(flashBytes)}</dd></div>
                <div><dt>Required board</dt><dd>{selectedTarget?.requiredBoard ?? "Select hardware above"}</dd></div>
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
                <input type="checkbox" checked={hardwareConfirmed} disabled={!selectedTarget} onChange={(event) => setHardwareConfirmed(event.target.checked)} />
                <span>{selectedTarget?.confirmation ?? "Select and verify the exact target first."}</span>
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
            <div><dt>Hardware</dt><dd>{manifest?.hardwareFamily ?? selectedTarget?.shortLabel ?? "—"}</dd></div>
            <div><dt>ESP-IDF</dt><dd>{manifest?.espIdfVersion ?? "—"}</dd></div>
            <div><dt>Upstream</dt><dd>{manifest?.upstreamTag ?? "—"}</dd></div>
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
        <span>TARGET-GATED USB FIRST-FLASH · WI-FI OTA ACTIVATION PENDING</span>
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
