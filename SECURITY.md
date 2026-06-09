# Security policy

This document explains how to report a security vulnerability in the
Cove Protocol contracts, what's in scope, and what we'll do in
response.

## Reporting a vulnerability

**Do NOT open a public GitHub issue for security bugs.** Public
disclosure before we can patch puts every COVE holder at risk.

Report via one of the following:

1. **Discord DM**: Drop into [discord.gg/AsjX6PkJbu](https://discord.gg/AsjX6PkJbu)
   and DM `@afatalerrror` (the project owner). Mention you have a
   security report — we'll move the conversation to a private channel.
2. **Email**: `security@covelabs.xyz`
3. **X DM**: [@cove_labs](https://twitter.com/cove_labs)

Discord is the fastest channel.

### What to include

- A description of the vulnerability
- The affected module(s) and file paths
- Proof-of-concept steps or transaction data (testnet, please)
- Your wallet address if you'd like to be eligible for a bounty
  (see below)
- Any suggested remediation

Encrypted communication is welcome — we'll exchange keys once initial
contact is made.

## Scope

**In scope:**

- All Move code under [`sources/`](sources/)
- Test suite logic under [`tests/`](tests/) that masks a real
  vulnerability in `sources/`

**Out of scope:**

- The off-chain orchestrator, agent, frontend, or other infrastructure
  not in this repo
- Theoretical attacks requiring impossible adversary assumptions (e.g.
  "if you control 51% of Sui validators…")
- UI/UX issues, typos, documentation suggestions (open a regular issue)
- Already-disclosed vulnerabilities we're working on (we'll tell you
  if your report duplicates an in-flight fix)

## Our response timeline

| Step | Target |
|---|---|
| Acknowledge receipt | Within 48 hours |
| Initial triage (in scope? duplicate? severity?) | Within 7 days |
| Fix in progress + ETA | Within 14 days for critical/high |
| Coordinated disclosure | 90 days from receipt, or sooner with mutual agreement |

If we can't meet a timeline, we'll explain why and propose a revised
one.

## Responsible disclosure

We ask that you:

- Give us a reasonable window to patch before public disclosure
  (default: 90 days, negotiable)
- Don't exploit the vulnerability beyond the minimum needed to prove
  it works — for testnet, light testing is fine; for mainnet, please
  STOP at proof-of-concept and report
- Don't access user data, drain funds, or interfere with the network's
  normal operation
- Don't social-engineer team members for credentials

In return we commit to:

- Acknowledging your work in the patched release notes (unless you
  prefer anonymity)
- Not pursuing legal action against good-faith researchers
- A bounty payment when funds allow (see below)

## Bug bounty

Verified security bugs are paid in COVE. Sizing is case-by-case based
on severity, impact, and quality of the report — we don't publish a
fixed table because real-world bugs rarely fit one. Higher-impact
findings (e.g., fund drain, supply manipulation) get materially
larger rewards than low-impact findings (e.g., griefing without fund
risk).

A formal Immunefi program is planned pre-mainnet, where terms will be
standardized and published publicly. Until then, treat anything here
as a good-faith arrangement between us and you, settled when funds
allow.

## Hall of fame

Researchers who responsibly disclose are listed here in the patched
release notes (or anonymously, if preferred):

*(empty — be the first)*
