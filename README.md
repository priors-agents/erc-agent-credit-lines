# Agent Credit Lines (draft ERC)

One interface for revolving credit to agent identities: how much an identity can borrow now, what it would cost, draw
it, how much closes it, repay it, mark it defaulted. Three events (`Borrowed`, `Repaid`, `Defaulted`) record every loan,
so a wallet, a payment client or a credit reader works with any conforming lender through one ABI.

Identities are token ids of an ERC-721 identity registry, such as the Identity Registry of ERC-8004 (Trustless Agents).

**Status: draft, submitted as [ethereum/ERCs#2104](https://github.com/ethereum/ERCs/pull/2104).** The text is in
[`ERCS/erc-draft_agent_credit_lines.md`](ERCS/erc-draft_agent_credit_lines.md). Its `eip: 99901` is a placeholder until
the ERC editors assign a number. Discussion: [Ethereum
Magicians](https://ethereum-magicians.org/t/erc-tba-agent-credit-lines/30023).

## Why

Agents pay for services before they are paid for their own work, so they need working capital. Lenders to ERC-8004
agents already exist (Priors and Nenrin on Robinhood Chain, for two), each with its own functions and events, so every
client integrates every lender separately. The calls are the same everywhere; this fixes them.

## What is here

| Path | What |
|---|---|
| `ERCS/erc-draft_agent_credit_lines.md` | The ERC text, in the ethereum/ERCs template |
| `src/IAgentCreditLine.sol` | The interface |
| `src/SimpleCreditLine.sol` | A minimal reference lender (not audited; not for real money) |
| `test/SimpleCreditLine.t.sol` | Foundry tests of the reference lender against the specification |
| `scripts/lint-erc.sh` | Lints the ERC text with eipw the way the ethereum/ERCs CI does |
| `eipw.toml` | The ethereum/ERCs repository's eipw configuration, copied as is |

## Checks

```bash
forge build
forge test
scripts/lint-erc.sh   # needs eipw: cargo install eipw --version 0.11.0 --locked
```

CI runs all three on every push (`.github/workflows/ci.yml`).

## Related drafts

- Agent Repay-First Payees: an agent's revenue address that pays its creditors first
  (github.com/priors-agents/erc-repay-first-payees).
- Agent Default Registry: lender-reported defaults any contract can check
  (github.com/priors-agents/erc-agent-default-registry).
- Credit history for ERC-8004 agents: a profile of the ERC-8004 Reputation Registry for loan outcomes
  (`docs/ERC-8004-CREDIT.md` in github.com/priors-agents/priors). This interface's three events are exactly the
  sources that profile reads.

## Licence

CC0 1.0 ([LICENSE.md](LICENSE.md)), as the ERC process requires.
