import * as sdk from "@earendil-works/pi-coding-agent";
import { registerPrecompactStow } from "./lib/fm-precompact-stow.ts";
import { createPiStowWorker } from "./lib/fm-pi-stow-worker.ts";
import { registerContextStowNudge } from "./lib/fm-context-stow-nudge.ts";

export default function (pi: sdk.ExtensionAPI): void {
  registerPrecompactStow(pi, createPiStowWorker(sdk));
  registerContextStowNudge(pi);
}
