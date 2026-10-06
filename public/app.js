"use strict";
const csrf = document.querySelector('meta[name="csrf-token"]')?.content;
const notice = (text) => {
  const el = document.getElementById("notice");
  el.textContent = text; el.hidden = false;
  setTimeout(() => { el.hidden = true; }, 5000);
};
async function api(url, options = {}) {
  const response = await fetch(url, { ...options, headers: { Accept: "application/json", "X-CSRF-Token": csrf, ...options.headers } });
  if (response.redirected) { location.href = response.url; throw new Error("Please sign in again"); }
  if (!response.ok) {
    const text = await response.text();
    const doc = new DOMParser().parseFromString(text, "text/html");
    throw new Error(doc.querySelector("h1")?.textContent || `Request failed (${response.status})`);
  }
  return response;
}
function mergeMessages(html, deleted = []) {
  const list = document.getElementById("messages");
  const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 100;
  deleted.forEach(id => document.getElementById(`message_${id}`)?.remove());
  const template = document.createElement("template"); template.innerHTML = html;
  template.content.querySelectorAll("article.message").forEach(node => {
    const existing = document.getElementById(node.id);
    if (existing) existing.replaceWith(node);
    else {
      const next = [...list.querySelectorAll("article.message")].find(item => Number(item.dataset.messageId) > Number(node.dataset.messageId));
      list.insertBefore(node, next || null);
    }
  });
  if (list.querySelector("article")) list.querySelector(".empty")?.remove();
  if (nearBottom) list.scrollTop = list.scrollHeight;
}
const chat = document.querySelector(".chat");
if (chat) {
  const room = chat.dataset.roomId;
  const messages = document.getElementById("messages");
  let cursor = Number(chat.dataset.cursor);
  let polling = false;
  messages.scrollTop = messages.scrollHeight;
  async function poll() {
    if (polling || document.hidden) return;
    polling = true;
    try {
      let more;
      do {
        const data = await (await api(`/rooms/${room}/events?after=${cursor}`)).json();
        mergeMessages(data.html, data.deleted); cursor = data.cursor; more = data.more;
      } while (more);
    } catch (error) { notice(error.message); }
    finally { polling = false; }
  }
  async function heartbeat() {
    if (!document.hidden) {
      try { await api(`/rooms/${room}/heartbeat`, {method: "POST"}); }
      catch (error) { notice(error.message); }
    }
  }
  heartbeat(); setInterval(heartbeat, 30000); setInterval(poll, 2000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) { heartbeat(); poll(); } });
  setInterval(async () => {
    if (document.hidden) return;
    try {
      const response = await fetch("/users/me/sidebar", {headers: {Accept: "text/html"}});
      if (response.ok && !response.redirected) document.querySelector("#sidebar nav").outerHTML = await response.text();
    } catch (_) { /* Retry at the next interval. */ }
  }, 10000);
  const composer = document.getElementById("composer");
  let posting = false;
  composer.addEventListener("submit", async event => {
    event.preventDefault(); if (posting) return;
    const input = document.getElementById("message-body");
    if (!input.value.trim() && !composer.querySelector('input[type="file"]').files.length) return;
    posting = true; const button = composer.querySelector("button"); button.disabled = true;
    // Retain this ID on a failed request so a retry cannot create duplicates.
    composer.dataset.clientId ||= crypto.randomUUID();
    const data = new FormData(composer);
    const span = document.createElement("span"); span.textContent = input.value;
    data.set("message[body]", span.innerHTML.replaceAll("\n", "<br>"));
    data.set("message[client_message_id]", composer.dataset.clientId);
    try {
      await api(composer.action, {method: "POST", body: data});
      composer.reset(); delete composer.dataset.clientId; await poll(); input.focus();
    } catch (error) { notice(error.message); }
    finally { posting = false; button.disabled = false; }
  });
  document.getElementById("message-body").addEventListener("keydown", event => {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) { event.preventDefault(); composer.requestSubmit(); }
  });
  document.getElementById("load-older")?.addEventListener("click", async event => {
    const button = event.currentTarget; button.disabled = true;
    try {
      const response = await fetch(`/rooms/${room}/messages?before=${button.dataset.before}`);
      if (!response.ok || response.redirected) throw new Error("Could not load messages");
      if (response.status === 204) { button.remove(); return; }
      const html = await response.text(); const template = document.createElement("template"); template.innerHTML = html;
      const first = template.content.querySelector("article");
      if (!first) { button.remove(); return; }
      const height = messages.scrollHeight;
      button.dataset.before = first.dataset.messageId;
      button.after(template.content);
      messages.scrollTop += messages.scrollHeight - height;
    } catch (error) { notice(error.message); }
    finally { button.disabled = false; }
  });
}
document.addEventListener("click", async event => {
  const button = event.target.closest("[data-action], [data-boost-id]"); if (!button) return;
  const message = button.closest("article.message"); if (!message) return;
  const id = message.dataset.messageId;
  try {
    if (button.dataset.action === "delete") {
      if (!confirm("Delete this message?")) return;
      await api(`/messages/${id}`, {method: "DELETE"}); message.remove();
    } else if (button.dataset.action === "boost") {
      const content = prompt("Boost this message with an emoji or a few words (16 characters)", "🙌");
      if (!content) return;
      await api(`/messages/${id}/boosts`, {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({content})});
      notice("Boost added");
    } else {
      if (!confirm("Remove your boost?")) return;
      await api(`/messages/${id}/boosts/${button.dataset.boostId}`, {method: "DELETE"}); button.remove();
    }
  } catch (error) { notice(error.message); }
});
document.getElementById("enable-notifications")?.addEventListener("click", async event => {
  try {
    if (!("serviceWorker" in navigator) || !("PushManager" in window)) throw new Error("Push notifications are not available in this browser");
    const settings = await (await api("/users/me/push_subscriptions")).json();
    if (!settings.public_key) throw new Error("The server administrator needs to configure Web Push first");
    const permission = await Notification.requestPermission();
    if (permission !== "granted") throw new Error("Notification permission was not granted");
    const registration = await navigator.serviceWorker.register("/service-worker.js");
    await navigator.serviceWorker.ready;
    const base64 = settings.public_key.replaceAll("-", "+").replaceAll("_", "/");
    const key = Uint8Array.from(atob(base64), char => char.charCodeAt(0));
    const subscription = await registration.pushManager.getSubscription() || await registration.pushManager.subscribe({userVisibleOnly: true, applicationServerKey: key});
    await api("/users/me/push_subscriptions", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(subscription)});
    notice("Notifications enabled"); event.target.textContent = "Notifications enabled";
  } catch (error) { notice(error.message); }
});
