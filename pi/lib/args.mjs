export function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

export function tokenizeArgs(args) {
  return String(args || "").trim().split(/\s+/).filter(Boolean);
}

export function argTokens(args) {
  if (Array.isArray(args)) return args.map(String).filter((arg) => arg.length > 0);
  return tokenizeArgs(args);
}

export function renderArgs(args) {
  return argTokens(args).join(" ");
}

export function renderShellArgs(args) {
  return argTokens(args).map(shellQuote).join(" ");
}
