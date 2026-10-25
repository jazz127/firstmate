import { spawn } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

function sample(ctx: ExtensionContext): Promise<string> {
  const percent = ctx.getContextUsage()?.percent;
  if (percent == null || process.env.FM_PRECOMPACT_STOW_ACTIVE === "1" || process.env.NO_MISTAKES_GATE) return Promise.resolve("");
  return new Promise((done) => {
    const child = spawn(`${root}/bin/fm-context-stow-nudge.sh`, ["--pi"], { stdio: ["pipe", "pipe", "ignore"] });
    let output = "";
    child.stdout.setEncoding("utf8").on("data", (part: string) => { output += part; });
    const timer = setTimeout(() => { child.kill("SIGTERM"); done(""); }, 5000);
    const finish = (value: string): void => { clearTimeout(timer); done(value); };
    child.once("error", () => finish(""));
    child.once("close", (code) => finish(code === 0 ? output.trim() : ""));
    child.stdin.on("error", () => {});
    child.stdin.end(JSON.stringify({ session_id: ctx.sessionManager.getSessionId(), percent }));
  });
}

export function registerContextStowNudge(pi: Pick<ExtensionAPI, "on" | "sendMessage">): void {
  pi.on("before_agent_start", async (_event, ctx) => {
    const content = await sample(ctx);
    if (content) return { message: { customType: "firstmate-sessionstart-nudge", content, display: false, details: { kind: "context-stow" } } };
  });
  pi.on("turn_end", async (_event, ctx) => {
    const content = await sample(ctx);
    if (content) pi.sendMessage({ customType: "firstmate-sessionstart-nudge", content, display: false, details: { kind: "context-stow" } }, { triggerTurn: true, deliverAs: "followUp" });
  });
  pi.on("session_compact", async (_event, ctx) => { await sample(ctx); });
}
