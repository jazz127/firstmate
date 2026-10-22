import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
export type StowRequest = { role: string; prompt: string; home: string };
export type StowWorker = (request: StowRequest, ctx: ExtensionContext, signal: AbortSignal) => Promise<string>;

export function registerPrecompactStow(adapter: Pick<ExtensionAPI, "on">, worker: StowWorker): void {
  adapter.on("session_before_compact", async (event, ctx) => {
    if (process.env.FM_PRECOMPACT_STOW_ACTIVE === "1" || process.env.NO_MISTAKES_GATE) return;
    try {
      const transcript = ctx.sessionManager.getSessionFile();
      if (!transcript || !ctx.model) return;
      const payload = JSON.stringify({
        hook_event_name: "PreCompact",
        session_id: ctx.sessionManager.getSessionId(),
        transcript_path: transcript,
        trigger: event.reason === "manual" ? "manual" : "auto",
        branch_entries: ctx.sessionManager.getBranch(),
      });
      await new Promise<void>((done) => {
        const controller = new AbortController();
        const child = spawn(`${root}/bin/fm-precompact-stow.sh`, ["--harness", "pi"], {
          cwd: root,
          env: process.env,
          stdio: ["pipe", "pipe", "ignore"],
        });
        const lines = createInterface({ input: child.stdout });
        let requested = false;
        lines.on("line", async (line) => {
          if (requested || controller.signal.aborted) return;
          requested = true;
          let status = 0;
          let output: string;
          try {
            output = await worker(JSON.parse(line) as StowRequest, ctx, controller.signal);
          } catch (error) {
            status = 2;
            output = String(error);
          }
          if (!controller.signal.aborted) child.stdin.end(`${JSON.stringify({ status, output })}\n`);
        });
        const timer = setTimeout(() => { child.kill("SIGTERM"); finish(); }, 75000);
        const finish = (): void => {
          clearTimeout(timer);
          controller.abort();
          lines.close();
          done();
        };
        child.once("error", finish);
        child.once("close", finish);
        child.stdin.on("error", () => {});
        child.stdin.write(`${payload}\n`);
      });
    } catch {}
  });
}
