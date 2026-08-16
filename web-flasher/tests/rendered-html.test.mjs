import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
}

test("server-renders the VHOS provisioner", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>VHOS Gateway Provisioner · VHOS<\/title>/i);
  assert.match(html, /Flash with a way back/);
  assert.match(html, /Classic ESP32 \+ MrDIY CAN Shield v1\.3\+/);
  assert.match(html, /ESP32-S3 \+ MeatPi WiCAN Pro/);
  assert.match(html, /SELECT HARDWARE BELOW/);
  assert.match(html, /BACK UP FULL FLASH/);
  assert.match(html, /INSTALL VERIFIED VHOS IMAGE/);
  assert.match(html, /RESTORE SELECTED BACKUP/);
  assert.doesNotMatch(html, /Your site is taking shape|Building your site/);
});

test("target manifests resolve to byte-exact local artifacts", async () => {
  const manifestNames = [
    "manifest-mrdiy-esp32-v13.json",
    "manifest-wican-pro-esp32s3.json",
  ];
  const chipFamilies = new Set();

  for (const manifestName of manifestNames) {
    const manifestUrl = new URL(`../public/firmware/${manifestName}`, import.meta.url);
    const manifest = JSON.parse(await readFile(manifestUrl, "utf8"));
    const artifactName = manifest.artifact.url.split("/").at(-1);
    const bytes = await readFile(new URL(`../public/firmware/${artifactName}`, import.meta.url));
    const digest = createHash("sha256").update(bytes).digest("hex");

    assert.equal(bytes.byteLength, manifest.artifact.byteCount);
    assert.equal(digest, manifest.artifact.sha256);
    chipFamilies.add(manifest.chipFamily);
  }

  assert.deepEqual(chipFamilies, new Set(["ESP32", "ESP32-S3"]));
});
