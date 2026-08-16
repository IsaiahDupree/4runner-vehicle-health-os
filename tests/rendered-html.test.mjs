import assert from "node:assert/strict";
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
  assert.match(html, /BACK UP FULL FLASH/);
  assert.match(html, /INSTALL VERIFIED VHOS IMAGE/);
  assert.match(html, /RESTORE SELECTED BACKUP/);
  assert.doesNotMatch(html, /Your site is taking shape|Building your site/);
});
