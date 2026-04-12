import json
import getpass
import re
import requests
from playwright.sync_api import sync_playwright

VERSION = "1.1.5 (NextData-Extraction)"

def run_cli_login():
    print(f"--- Scalable Script Version {VERSION} ---")
    email = input("E-Mail: ")
    password = getpass.getpass("Passwort: ")

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context()
        page = context.new_page()

        print("Logge ein und warte auf Freigabe am Handy...")
        page.goto("https://de.scalable.capital/secure-login")
        
        page.wait_for_selector('input[name="username"]')
        page.fill('input[name="username"]', email)
        page.fill('input[name="password"]', password)
        page.click('button[type="submit"]')

        try:
            page.wait_for_url("**/cockpit/**", timeout=90000)
            print("Login erfolgreich!")
            
            # --- NEU: ID direkt aus dem HTML extrahieren ---
            print("Extrahiere User-ID aus Seiteninhalt...")
            content = page.content()
            
            # Wir suchen den Inhalt des __NEXT_DATA__ Skripts
            match = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', content)
            if match:
                next_data = json.loads(match.group(1))
                # Pfad laut deinem Log: props -> pageProps -> middlewareProps -> m1 -> session -> user -> userId
                try:
                    account_id = next_data['props']['pageProps']['middlewareProps']['m1']['session']['user']['userId']
                    print(f"ID gefunden (via __NEXT_DATA__): {account_id}")
                except KeyError:
                    # Alternativer Pfad, falls m1 sich ändert
                    account_id = None
                    print("Warnung: userId-Pfad in __NEXT_DATA__ nicht gefunden.")
            else:
                account_id = None
                print("Warnung: __NEXT_DATA__ Tag nicht gefunden.")

        except Exception as e:
            print(f"Fehler während der Extraktion: {e}")
            browser.close()
            return

        session_cookies = {c['name']: c['value'] for c in context.cookies()}
        user_agent = page.evaluate("navigator.userAgent")
        browser.close()

    if not account_id:
        print("\n" + "!"*20 + " FEHLER: ID NICHT GEFUNDEN " + "!"*20)
        print("Konnte userId weder im HTML noch via API finden.")
        # Hier könnte man zur Not den alten API-Call als Fallback einbauen
        return

    # --- AB HIER: DATENABFRAGE WIE GEWOHNT ---
    graphql_url = "https://de.scalable.capital/cockpit/graphql"
    headers = {
        "User-Agent": user_agent,
        "Content-Type": "application/json",
        "Referer": "https://de.scalable.capital/cockpit/dashboard"
    }

    print("Rufe Kontodaten ab...")
    batch_payload = [
        {
            "operationName": "GetFinalData",
            "variables": {"accountId": account_id},
            "query": """
                query GetFinalData($accountId: ID!) {
                  account(id: $accountId) {
                    savingsAccounts {
                      id
                      personalizations { name }
                      ... on OvernightSavingsAccount { totalAmount interestRate }
                    }
                    brokerPortfolios {
                      personalizations { name }
                      cashAccount { iban }
                    }
                  }
                  personOverview(id: $accountId) {
                    personalDetails { firstName lastName }
                    contactData { email }
                  }
                }"""
        }
    ]

    response = requests.post(graphql_url, json=batch_payload, cookies=session_cookies, headers=headers)
    
    # Fehlerprüfung für den Batch-Call
    if response.status_code != 200:
        print(f"Fehler beim API-Abruf: Status {response.status_code}")
        print(response.text)
        return

    data_list = response.json()
    # Da es ein Batch ist, nehmen wir das erste Ergebnis
    data = data_list[0].get('data', {})

    print("\n" + "="*50)
    print("SALDO-ÜBERSICHT")
    print("="*50)

    if 'personOverview' in data:
        po = data['personOverview']
        print(f"Kunde:     {po['personalDetails']['firstName']} {po['personalDetails']['lastName']}")

    acc = data.get('account', {})
    for s in acc.get('savingsAccounts', []):
        print(f"Tagesgeld: {s.get('totalAmount', 0.0):,.2f} € (Zins: {s.get('interestRate', 0.0)*100:.2f} %)")
    
    for b in acc.get('brokerPortfolios', []):
        print(f"Broker-IBAN: {b['cashAccount']['iban']}")
    print("="*50)

if __name__ == "__main__":
    run_cli_login()