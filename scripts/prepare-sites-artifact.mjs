import { cpSync, mkdirSync } from "node:fs";

const manifestDirectory = new URL("../dist/.openai/", import.meta.url);

mkdirSync(manifestDirectory, { recursive: true });
cpSync(
  new URL("../.openai/hosting.json", import.meta.url),
  new URL("hosting.json", manifestDirectory),
);
