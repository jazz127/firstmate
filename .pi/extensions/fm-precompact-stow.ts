import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { registerPrecompactStow } from "./lib/fm-precompact-stow.ts";

export default function (pi: ExtensionAPI): void {
  registerPrecompactStow(pi);
}
