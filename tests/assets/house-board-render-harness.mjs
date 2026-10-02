// Execute a built house board under a minimal DOM and report visible behavior.
import fs from "node:fs";
import vm from "node:vm";

const html = fs.readFileSync(process.argv[2], "utf8");
const data = html.match(/<script id="house-data" type="application\/json">([\s\S]*?)<\/script>/);
const scripts = [...html.matchAll(/<script(?: [^>]*)?>([\s\S]*?)<\/script>/g)];
if (!data || scripts.length < 2) throw new Error("built board has no executable payload");

class Element {
  constructor(tag = "div") {
    this.tagName = tag;
    this.children = [];
    this.dataset = {};
    this.hidden = false;
    this.value = "";
    this._text = "";
    this.handlers = {};
  }
  set textContent(value) { this._text = String(value); this.children = []; }
  get textContent() { return this._text + this.children.map(child => child.textContent).join(""); }
  appendChild(child) { this.children.push(child); return child; }
  replaceChildren(...children) { this._text = ""; this.children = children; }
  addEventListener(name, handler) { this.handlers[name] = handler; }
}
const ids = ["house-data", "stamp", "lines", "stats", "search", "project", "label", "state", "posture", "age", "sort", "result-count", "features", "empty"];
const elements = Object.fromEntries(ids.map(id => [id, new Element()]));
elements["house-data"].textContent = data[1];
elements.sort.value = "project";
const document = {
  getElementById(id) { if (!elements[id]) throw new Error("unknown id " + id); return elements[id]; },
  createElement(tag) { return new Element(tag); },
};
const window = {};
vm.runInNewContext(scripts.at(-1)[1], {document, window, console});
for (const arg of process.argv.slice(3)) {
  const equal = arg.indexOf("=");
  const id = arg.slice(0, equal);
  if (!elements[id] || equal < 0) throw new Error("bad filter " + arg);
  elements[id].value = arg.slice(equal + 1);
  elements[id].handlers[id === "search" ? "input" : "change"]();
}
const payload = {
  count: elements["result-count"].textContent,
  stats: elements.stats.children.map(item => item.textContent),
  names: elements.features.children.map(row => row.children[0].children[0].textContent),
  rows: elements.features.children.map(row => row.textContent),
  visibleProjects: elements.lines.children.filter(card => !card.hidden).map(card => card.dataset.project),
  empty: !elements.empty.hidden,
};
process.stdout.write(JSON.stringify(payload) + "\n");
