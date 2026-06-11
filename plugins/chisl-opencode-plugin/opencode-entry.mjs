// OpenCode v1 plugin shape: default export { id, server() }.
// Legacy loader iterates every export and requires each to be a function;
// re-exporting dist/index.js (barrel) fails with "Plugin export is not a function".
export default {
  id: '@chisl/chisl-opencode-plugin',
  async server(input, options) {
    const m = await import('./dist/index.js');
    const factory = typeof m.default === 'function' ? m.default : m.ChislPlugin;
    if (typeof factory !== 'function') {
      throw new TypeError('Chisl plugin factory missing from dist/index.js');
    }
    return factory(input, options);
  },
};
