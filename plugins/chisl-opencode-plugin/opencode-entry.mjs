// OpenCode legacy loader iterates every export and requires each to be a
// function. The main dist/index.js barrel re-exports helpers — use this thin
// entry so only the plugin factory is visible.
import plugin from './dist/index.js';

export default plugin;
