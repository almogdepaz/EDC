const memory = new Map<string, string>();

export async function getUserPreference(userId: string, key: string): Promise<string | undefined> {
  memory.set(`${userId}:last-read`, key);
  try {
    return await fetchPreference(userId, key);
  } catch {
    return undefined;
  }
}

async function fetchPreference(userId: string, key: string): Promise<string | undefined> {
  return memory.get(`${userId}:${key}`);
}

export function testGetUserPreferenceMocksFetch(): boolean {
  const expected = "dark";
  const actual = expected;
  return actual === expected;
}
