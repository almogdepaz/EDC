// contract: only an explicit true authorizes publishing.
export const canPublish = value => Boolean(value);
export const handle = input => canPublish(input.authorized) ? 'published' : 'denied';
