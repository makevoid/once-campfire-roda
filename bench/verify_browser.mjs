// Real-browser checks against an explicitly marked, disposable fixture.
// Tooling lives under tmp; Node and Playwright are not app dependencies.
import { createRequire } from "node:module"
import { readFileSync, mkdirSync, writeFileSync } from "node:fs"
import { resolve } from "node:path"
import assert from "node:assert/strict"

const require = createRequire(import.meta.url)
const { chromium } = require(resolve(process.env.PLAYWRIGHT_PATH || "tmp/browser-audit/node_modules/playwright-core"))
const labels = JSON.parse(readFileSync(process.argv[2], "utf8"))
assert.equal(labels.fixture, "campfire-roda-benchmark-v1")
const base = process.env.BASE_URL || "http://127.0.0.1:9396"
assert.ok(["127.0.0.1", "localhost"].includes(new URL(base).hostname))
const output = process.env.BROWSER_OUTPUT || "tmp/browser-audit/results"
mkdirSync(output, { recursive: true })
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: true })
const errors = [], checks = [], socketMessages = [], requests = []
const check = (value, name) => { assert.ok(value, name); checks.push(name) }
let page
try {
  const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } })
  page = await context.newPage()
  await page.addInitScript(() => document.addEventListener("lexxy:initialize", event => { event.target.dataset.auditReady = "true" }))
  page.on("pageerror", error => errors.push(error.message))
  page.on("websocket", socket => socket.on("framereceived", event => socketMessages.push(event.payload.toString())))
  page.on("console", message => { if (message.type() === "error") errors.push(message.text()) })
  page.on("response", response => { if (response.status() >= 400) errors.push(`${response.status()} ${response.url()}`) })
  page.on("request", request => { if (request.method() !== "GET" && request.url().includes("/messages/")) requests.push({ url: request.url(), method: request.method(), body: request.postData() }) })
  await page.goto(`${base}/session/new`)
  await page.locator('input[name="email_address"]').fill(labels["emails.david"])
  await page.locator('input[name="password"]').fill(labels["passwords.all"])
  await page.locator('button[name="log_in"]').click()
  await page.waitForURL(`**/rooms/${labels["rooms.watercooler"]}`)
  await page.locator("lexxy-editor [contenteditable=true]").waitFor()
  await page.locator("#shared_rooms a").first().waitFor()
  await page.waitForFunction(() => document.querySelector('turbo-cable-stream-source[channel="RoomMessagesChannel"]')?.hasAttribute("connected"))
  check(await page.locator(".message[data-message-id]").count() > 0, "messages rendered")
  check(await page.locator("#composer lexxy-editor").evaluate(element => typeof element.value === "string"), "Lexxy initialized")
  await page.evaluate(() => Promise.all(document.getAnimations()
    .filter(animation => Number.isFinite(animation.effect?.getComputedTiming().endTime))
    .map(animation => animation.finished.catch(() => {}))))
  await page.screenshot({ path: `${output}/room-desktop.png` })
  const text = `Browser port audit ${Date.now()}`
  await page.locator("#composer [contenteditable=true]").fill(text)
  await page.getByRole("button", { name: "Send Message", exact: true }).click()
  const message = page.locator(".message[data-message-id]").filter({ hasText: text })
  await page.waitForFunction(text => [...document.querySelectorAll(".message[data-message-id]")].some(node => node.textContent.includes(text) && Number(node.dataset.messageId) > 0), text)
  check(await message.count() === 1, "composer creates one persisted message")
  const messageId = await message.getAttribute("data-message-id")
  // Both the HTTP response and the broadcast replace the optimistic message.
  // Wait for both before interacting with a menu inside that message.
  const deadline = Date.now() + 5000
  while (!socketMessages.some(packet => packet.includes(text))) {
    assert.ok(Date.now() < deadline, "message arrived over WebSocket")
    await new Promise(resolve => setTimeout(resolve, 25))
  }
  await page.waitForFunction(() => !document.querySelector("turbo-stream"))
  await page.waitForTimeout(200)
  await message.locator("summary.message__options-btn").click()
  await message.getByRole("button", { name: "Thumbs up", exact: true }).click()
  await message.locator(".boost-item").waitFor()
  check(await message.locator(".boost-item").count() === 1, "quick boost updates Turbo frame")
  check(await message.locator('[data-boost-delete-target="content"]').textContent() === "👍", "Unicode reaction preserved")
  await message.locator("summary.message__options-btn").click()
  await message.locator(".message__edit-btn").click()
  const editor = page.locator('.composer--edit lexxy-editor[data-audit-ready="true"] [contenteditable="true"]')
  await editor.click()
  await editor.press("ControlOrMeta+End")
  await editor.pressSequentially(" edited")
  await page.waitForFunction(text => document.querySelector('.composer--edit lexxy-editor').value.includes(text), `${text} edited`)
  await page.getByRole("button", { name: "Save changes", exact: true }).click()
  await page.locator(`[data-message-id="${messageId}"] [data-reply-target="body"]`).filter({ hasText: `${text} edited` }).waitFor()
  check(await page.locator('.composer--edit').count() === 0, "edit saves and closes frame")
  await page.goto(`${base}/searches?q=${encodeURIComponent(text)}`)
  await page.locator(`.message[data-message-id="${messageId}"]`).waitFor()
  check(await page.locator(`.message[data-message-id="${messageId}"]`).count() === 1, "search finds posted message")
  await page.goto(`${base}/users/me/profile`)
  await page.locator('input[name="user[name]"]').waitFor()
  check(await page.locator('input[name="user[name]"]').inputValue() === "David", "profile form loads")
  await page.goto(`${base}/rooms/${labels["rooms.watercooler"]}`)
  await page.setViewportSize({ width: 390, height: 844 })
  await page.locator("#composer [contenteditable=true]").waitFor()
  await page.screenshot({ path: `${output}/room-mobile.png` })
  check(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), "mobile viewport has no horizontal overflow")
  // Remove the test message through the authenticated application endpoint.
  const removed = await page.evaluate(async ({ room, id }) => {
    const response = await fetch(`/rooms/${room}/messages/${id}`, { method: "DELETE", headers: { Accept: "text/vnd.turbo-stream.html" } })
    return response.status
  }, { room: labels["rooms.watercooler"], id: messageId })
  check(removed === 200, "message cleanup")
  check(errors.length === 0, `browser errors: ${errors.join("; ")}`)
  writeFileSync(`${output}/report.json`, JSON.stringify({ status: "passed", browser: browser.version(), checks, errors }, null, 2) + "\n")
  console.log(JSON.stringify({ status: "passed", checks: checks.length, output }))
} catch (error) {
  if (page) await page.screenshot({ path: `${output}/failure.png` }).catch(() => {})
  writeFileSync(`${output}/failure.json`, JSON.stringify({ error: String(error), checks, errors, requests }, null, 2) + "\n")
  throw error
} finally {
  await browser.close()
}
