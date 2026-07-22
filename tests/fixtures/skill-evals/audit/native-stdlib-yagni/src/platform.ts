export interface RandomIdProvider {
  next(): string;
}

export class BrowserRandomIdProvider implements RandomIdProvider {
  next(): string {
    return Math.random().toString(36).slice(2);
  }
}

export class IdFactory {
  constructor(private readonly provider: RandomIdProvider = new BrowserRandomIdProvider()) {}
  createId(): string {
    return this.provider.next();
  }
}

export function copyToClipboard(text: string): Promise<void> {
  const area = document.createElement("textarea");
  area.value = text;
  document.body.appendChild(area);
  area.select();
  document.execCommand("copy");
  document.body.removeChild(area);
  return Promise.resolve();
}

export function normalize(value: string): string {
  try {
    return value.trim();
  } catch (error) {
    throw error;
  }
}

// edc-debt: keep legacy id format for old exports
export const legacyIdPrefix = "legacy-";
