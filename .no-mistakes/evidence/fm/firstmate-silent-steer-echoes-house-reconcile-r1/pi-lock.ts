import { writeFileSync } from 'node:fs';
export default function(pi: any) {
 pi.on('session_start', async (_event: any, ctx: any) => {
  const result = await pi.exec(`${process.cwd()}/bin/fm-lock.sh`, []);
  writeFileSync(`${process.env.FM_HOME}/lock-acquisition.txt`, JSON.stringify(result));
  writeFileSync(`${process.env.FM_HOME}/session-file.txt`, ctx.sessionManager.getSessionFile());
  pi.sendMessage({ customType: 'lab-visible-check', content: 'Live Pi replay check: routine outcomes must remain hidden.', display: true }, { triggerTurn: false });
 });
}
