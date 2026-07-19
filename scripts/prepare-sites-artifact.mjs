import { copyFileSync, cpSync, mkdirSync, writeFileSync } from "node:fs";

const manifestDirectory = new URL("../dist/.openai/", import.meta.url);
const serverDirectory = new URL("../dist/server/", import.meta.url);
const serverEntrypoint = new URL("index.js", serverDirectory);

mkdirSync(manifestDirectory, { recursive: true });
cpSync(
  new URL("../.openai/hosting.json", import.meta.url),
  new URL("hosting.json", manifestDirectory),
);

copyFileSync(serverEntrypoint, new URL("vinext-handler.js", serverDirectory));
writeFileSync(
  serverEntrypoint,
  `import handler from "./vinext-handler.js";

export default {
  fetch(request, environment, context) {
    return handler(request, environment, context);
  },
};
`,
);
