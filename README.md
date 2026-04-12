# Scalable Capital Overnight Money Extension for MoneyMoney

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A [MoneyMoney](https://moneymoney-app.com) extension that retrieves the balance and transaction history of your **Scalable Capital overnight money account** (Tagesgeld).

## Requirements

- MoneyMoney **beta version** (unsigned extensions are not supported by the release version)
- A Scalable Capital account with an overnight money (Tagesgeld) account
- The Scalable Capital mobile app for 2FA confirmation

## Installation

1. Download [`Scalable-Capital-Tagesgeld.lua`](https://github.com/jens62/Scalable-MoneyMoney-OvernightMoney/raw/main/Scalable-Capital-Tagesgeld.lua) from this repository.
2. Copy the file into the MoneyMoney extensions folder:
   ```
   ~/Library/Containers/com.moneymoney-app.retail/Data/Library/Application Support/MoneyMoney/Extensions
   ```
3. In MoneyMoney, go to **Preferences → Extensions** and **disable the signature check** — this extension is not (yet) signed.

No restart is required; the extension loads automatically.

## Usage

1. In MoneyMoney, choose **Add Account → Others → Scalable Capital Tagesgeld**.
2. Enter your Scalable Capital credentials.
3. Confirm the login in the **Scalable Capital app** when prompted (push notification, up to 120 seconds).

## Remarks

- **Separate 2FA per refresh:** This extension cannot share the authentication session with Scalable Capital's clearing or broker account. Each refresh triggers its own 2FA confirmation in the Scalable Capital app. This is a fundamental limitation of MoneyMoney's Lua extension model — the required HttpOnly session cookie is not accessible from Lua extensions.
- Transactions are fetched in full (up to 500 entries) and filtered locally by MoneyMoney's "since" date.

## CLI Balance Checker (Python)

`scalable_capital_balance.py` is a standalone script for quickly checking your Scalable Capital balance from the terminal. It uses Playwright to drive a headless Chromium browser through the full login flow (including mobile 2FA approval) and prints your overnight money balance, interest rate, and broker IBAN.

**Install dependencies:**
```bash
pip install -r requirements.txt
playwright install chromium
```

**Run:**
```bash
python scalable_capital_balance.py
```

## Version

Current version: **1.09**
