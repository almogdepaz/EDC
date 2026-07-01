# EDC Context

| Path | Module |
|---|---|
| src/webhook.ts | billing-webhooks |
| src/retry.ts | billing-domain |

Critical invariant: billing-domain owns retry policy and provider error classification.
