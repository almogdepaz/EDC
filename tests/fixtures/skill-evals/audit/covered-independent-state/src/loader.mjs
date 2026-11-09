// Contract: only the current request may publish data, error, or loading state.
// panelOpen is independent view state; loading with an open or closed panel is valid.
export function createLoader() {
  let current = 0;
  const state = { data: null, error: null, loading: false, panelOpen: false };
  return {
    snapshot: () => ({ ...state }),
    setPanelOpen(open) { state.panelOpen = open; },
    cancel() {
      current += 1;
      state.loading = false;
    },
    async load(fetchValue) {
      const request = ++current;
      state.loading = true;
      state.error = null;
      try {
        const value = await fetchValue();
        if (request === current) state.data = value;
      } catch (error) {
        if (request === current) state.error = error.message;
      } finally {
        if (request === current) state.loading = false;
      }
    },
  };
}
