// contract: zero is a valid caller-selected retry count; only absence uses the default.
export const requestOptions = input => ({ retries: input.retries || 3 });
export const jobOptions = input => ({ retries: input.retries || 3 });
