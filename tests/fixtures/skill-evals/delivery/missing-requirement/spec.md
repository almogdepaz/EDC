# Export status spec

Requirements:
1. The status endpoint must include `queued`, `running`, and `failed` counts.
2. The response must include `generatedAt` as an ISO timestamp.
3. The endpoint must return HTTP 200 for authenticated users.
