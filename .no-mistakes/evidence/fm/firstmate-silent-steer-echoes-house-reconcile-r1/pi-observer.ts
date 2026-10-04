import { writeFileSync } from 'node:fs';
export default function(pi: any) {
 pi.on('session_start', (_event: any, ctx: any) => {
  const serialized = [ctx.sessionManager.getHeader(), ...ctx.sessionManager.getEntries()].map((row: any) => JSON.stringify(row)).join('\n')+'\n';
  writeFileSync(ctx.sessionManager.getSessionFile(), serialized);
  writeFileSync('/Users/jarad/.no-mistakes/evidence/01M4372PFF3JWKYX618ESNHJ6Q/live-pi-session.jsonl', ctx.sessionManager.getEntries().map((row: any) => JSON.stringify(row)).join('\n')+'\n');
 });
}
