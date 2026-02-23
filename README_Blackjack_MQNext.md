# Blackjack (MQNext) — Created by Cannonballdex™

Simple in-game Blackjack for EverQuest using MacroQuest (MQNext) + ImGui.

---

## Features
- Dealer peek rule (Ace / 10 upcard)
- Insurance + Even Money
- Split, Double Down, Late Surrender
- Blackjack payout (3:2)
- Dealer soft-17 configurable
- Persistent bankroll (saved per character)
- ImGui UI with:
  - Bet slider + +/- buttons
  - Action buttons
  - Last round results always visible
- Auto offer to reset bankroll when below minimum bet

---

## Betting Rules
- Start bankroll: **100,000**
- Min bet: **100**
- Max bet: **10,000**
- Bet increments: **100**

---

## Install
1. Save script in:

```
C:\MQNext\lua\blackjack\
```

2. Run in game:

```
/lua run blackjack
```

---

## Commands

```
/blackjack start
/blackjack bet <amount>
/blackjack hit
/blackjack stand
/blackjack double
/blackjack split
/blackjack surrender
/blackjack insurance
/blackjack evenmoney
/blackjack noinsurance
/blackjack status
/blackjack gui
/blackjack reset
/blackjack quit
```

---

## Config Save Location
Per-character file:

```
C:\MQNext\config\blackjack_<Character>.lua
```

Stores:
- bankroll
- last bet

---

## Notes
- If suit symbols don’t render, change suits to:
  ```lua
  {"S","H","D","C"}
  ```
- If bankroll drops below minimum bet, GUI shows a reset button.

---

## Credit
**Created by Cannonballdex™**
