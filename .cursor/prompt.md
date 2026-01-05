# Prompt Templates (Use inside Cursor)

Copy/paste these prompts when working with Cursor.

---

## 1) “Audit and Patch” Prompt
You are a senior DeFi auditor. 
Given this file + the vault architecture, identify:
- compile errors
- storage layout risks
- accounting invariants violations
- reentrancy / external call hazards
Then produce:
1) short summary of issues
2) rewritten contract (full file)
3) list of invariants impacted
4) test cases to add in Foundry

File:
```solidity
<PASTE CODE>
