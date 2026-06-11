// OpenCode legacy loader: every export value must be a function (or v1 {server}).
// Never re-export dist/index.js — its namespace breaks loading.
import { createPlugin } from './dist/capabilities.js';

export default async function chislOpencodePlugin(input, options) {
  return createPlugin(input, options);
}
