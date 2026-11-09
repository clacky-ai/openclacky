// remend bundle entry — exposes a single `remend` global that closes unfinished
// markdown in a streaming preview. Build:
//   npx esbuild entry.js --bundle --minify --format=iife --outfile=remend.min.js
import remend from "remend";

globalThis.remend = remend;
