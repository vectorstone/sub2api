# Unified access for every AI workflow

> One API key routes requests across Claude, GPT, Gemini and other upstream providers with transparent billing and operational control.

## Why teams choose this gateway

- **OpenAI-compatible** request surface for faster client integration
- **Failover-ready** account pools to reduce rate-limit interruptions
- **Transparent usage** with wallet, quota and per-model tracking
- **Centralized access** for individual users, teams and internal tools

## What you get

### Drop-in routing
Use a single endpoint and one credential to access multiple providers without maintaining separate subscriptions and client code for each one.

### Reliable delivery
Spread traffic across multiple upstream accounts, keep sticky sessions where needed, and reduce the impact of provider-side throttling.

### Visible cost control
Track usage in real time, apply rate multipliers, quotas and subscriptions, and give users a self-serve dashboard for keys and consumption.

## Quick example

```bash
curl https://your-domain.example/v1/chat/completions \
  -H "Authorization: Bearer sk-xxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4.1",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

## Best fit scenarios

- Internal AI gateway for a small team
- Unified relay for multiple personal subscriptions
- Customer-facing API resale with quotas and usage billing
- Multi-provider backup path for production workloads

---

**Ready to start?** Sign in, create your key, and route your first request in minutes.
