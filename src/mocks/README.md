StrategyAaveMock
      │
      │ supply / withdraw
      ▼
MockAavePool
      │
      │ mint / burn
      ▼
MockAToken   (from Aave repo)
      │
      │ balanceOf() uses liquidityIndex
      ▼
Interest accrual (MockAaveInterestRate)


1. setNormal()
2. user deposit
3. harvest() → deploy
4. wait 1 day
5. oracle.latestYield() → APY ~5%
6. setStress()
7. withdraw 50%
8. observe loss / delay
9. setCrisis()
10. emergencyExit()
