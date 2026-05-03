-- Scalable Capital Tagesgeld - MoneyMoney Web Banking Extension
-- Zeigt Kontostand und Transaktionen des Scalable Capital Tagesgeldkontos.
--
-- Login-Flow (verifiziert per HAR-Analyse):
--   1. GET  /auth/login                  -> Auth0 OAuth2 Redirect-Kette
--   2. GET  /u/login?state=...           -> Auth0 Formular
--   3. POST /u/login                     -> Credentials (username, password, action=default)
--   4. GET  /auth/mfa-check              -> userId aus __NEXT_DATA__ extrahieren
--   5. POST /auth/graphql start2faOnLogin(input:{userId,deviceType,deviceName})
--   6. POST /auth/graphql validate2faOnLogin(input:{userId,mfaSessionId}) pollen
--   7. POST /cockpit/graphql             -> Kontodaten / Kontostand
--   8. POST /interest/api/graphql/       -> Transaktionen

-- ---------------------------------------------------------------------------
-- NICHT IMPLEMENTIERT: Gruppen-2FA-Sharing
-- ---------------------------------------------------------------------------
-- Problem: MoneyMoney erlaubt das Zusammenfassen mehrerer Konten einer Bank
-- in einer Gruppe. Innerhalb der Gruppe wird normalerweise nur eine einzige
-- 2FA-Bestaetigung benoetigt. Fuer native (gebundelte) Erweiterungen
-- funktioniert das, weil MoneyMoney den Cookie-Speicher auf OS-Ebene zwischen
-- den Verbindungen teilt.
--
-- Fuer Lua-Erweiterungen ist das NICHT moeglich, weil:
--   a) connection:getCookies() nur Non-HttpOnly-Cookies liefert (analog zu
--      document.cookie im Browser). Das eigentliche Auth-Session-Cookie
--      (appSession = JWE, ~3850 Zeichen, Algo: dir/A256GCM) ist HttpOnly und
--      damit fuer Lua grundsaetzlich unsichtbar.
--   b) connection:request() ignoriert manuell gesetzte Cookie-Header vollstaendig;
--      der interne Cookie-Jar ist nicht von aussen beschreibbar.
--   c) setCookie() setzt Cookies nur im internen Jar, aber ohne den echten
--      HttpOnly-Auth-Cookie hat jede Anfrage UNAUTHENTICATED zurueck.
--
-- Folgende Ansaetze wurden ausprobiert und sind alle gescheitert:
--
--   v1.01  Retry-Loop (30 s) vor dem Login: Warten ob die native Extension
--          die Auth schon abgeschlossen hat und Cookies geteilt werden.
--          Ergebnis: Cookies werden zwischen nativen und Lua-Extensions
--          nicht geteilt. Timing spielt keine Rolle.
--
--   v1.02  Abfrage is2faOnLoginEnabled via Auth-GraphQL nach dem Credential-
--          Login: sollte pruefen ob ein gueltige MFA-Session existiert.
--          Ergebnis: Feld "Invalid Input" (Column 21). Das Feld ist nur im
--          nativen secure-login-Flow erreichbar, nicht nach Auth0-OAuth2.
--
--   v1.03  Selbe Abfrage ohne userId-Argument.
--          Ergebnis: Identischer Fehler "Invalid Input" an Column 21.
--          Das Feld existiert im Schema fuer diese Session schlicht nicht.
--
--   v1.04  Kompletten __NEXT_DATA__-Inhalt loggen um verborgene Session-
--          State-Felder zu finden (z.B. mfaStatus, groupToken).
--          Ergebnis: MoneyMoney-Log wird bei ~2000 Zeichen abgeschnitten.
--          Keine verwertbaren Session-State-Felder gefunden.
--
--   v1.05  getCookies() nach erfolgreichem Login speichern (LocalStorage),
--          beim naechsten Run per setCookie() wiederherstellen.
--          Ergebnis beim zweiten Run: setCookie() ohne vorherigen URL-Kontext
--          assoziiert den Cookie nicht mit der richtigen Domain -> UNAUTHENTICATED.
--
--   v1.06  Manuellen Cookie-Header direkt in connection:request() setzen.
--          Ergebnis: MoneyMoney ignoriert manuell gesetzte Cookie-Header
--          komplett; der interne Jar wird immer vorrangig verwendet.
--
--   v1.07  Dummy-POST zu COCKPIT_GRAPHQL vor setCookie() um URL-Kontext zu
--          etablieren; danach gespeicherten Cookie per setCookie() einsetzen.
--          setCookie() gibt true zurueck (technisch erfolgreich), aber Ping-
--          Request liefert trotzdem UNAUTHENTICATED.
--          Ursache: Das eigentliche Session-Cookie ist HttpOnly und wird von
--          getCookies() gar nicht erst zurueckgegeben (s. Punkt a oben).
--
--   v1.08  ALLE von getCookies() gelieferten Cookies (nicht nur appSession)
--          speichern und wiederherstellen.
--          Ergebnis: Immer noch UNAUTHENTICATED. Zwei simultane 2FA-
--          Aufforderungen erschienen, da beide Extensions gleichzeitig starteten.
--
-- Fazit: Das fehlende HttpOnly-Cookie ist die Root Cause. Da MoneyMoney keine
-- API bereitstellt um HttpOnly-Cookies zwischen Extensions zu teilen, ist das
-- Problem mit dem Lua-Extension-Modell grundsaetzlich nicht loesbar.
-- Die Extension benoetigt daher bei jedem Refresh eine eigene 2FA-Bestaetigung.
-- ---------------------------------------------------------------------------

WebBanking{
  version     = 1.10,
  url         = "https://de.scalable.capital",
  services    = {"Scalable Capital Tagesgeld"},
  description = string.format(MM.localizeText("Get balance and transactions from %s."), "Scalable Capital Tagesgeld"),
}

local connection = nil
local userId     = nil

local AUTH_BASE        = "https://de.scalable.capital/auth"
local AUTH_GRAPHQL     = "https://de.scalable.capital/auth/graphql"
local COCKPIT_GRAPHQL  = "https://de.scalable.capital/cockpit/graphql"
local INTEREST_GRAPHQL = "https://de.scalable.capital/interest/api/graphql/"
local AUTH0_HOST       = "https://secure.scalable.capital"

-- ---------------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------------

-- URL-Encoding fuer Formular-POST
local function urlencode(s)
  s = tostring(s)
  return s:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

-- Warten per Busy-Loop
local function sleep(seconds)
  local t = os.time()
  repeat until os.time() >= t + seconds
end

-- ISO-8601-String -> Unix-Timestamp (Zahl) fuer bookingDate/valueDate.
-- MoneyMoney erwartet an dieser Stelle eine Zahl, kein Datums-Table.
local function isoToTimestamp(s)
  if not s then return 0 end
  local y, mo, d, h, mi, se = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)")
  if not y then
    y, mo, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
    h, mi, se = 12, 0, 0
  end
  if not y then return 0 end
  return os.time({
    year  = tonumber(y),
    month = tonumber(mo),
    day   = tonumber(d),
    hour  = tonumber(h  or 12),
    min   = tonumber(mi or 0),
    sec   = tonumber(se or 0),
  })
end

-- GraphQL POST, gibt geparste JSON-Tabelle zurueck
local function graphql(url, query, variables, operationName, referer)
  local payload = {query = query}
  if variables     then payload.variables     = variables     end
  if operationName then payload.operationName = operationName end

  local body = JSON():set(payload):json()
  local hdrs = {
    ["Content-Type"] = "application/json",
    ["Accept"]       = "application/json",
    ["Referer"]      = referer or "https://de.scalable.capital/cockpit/dashboard",
  }

  local response = connection:request("POST", url, body, "application/json", hdrs)
  return JSON(response):dictionary()
end

-- ---------------------------------------------------------------------------
-- SupportsBank
-- ---------------------------------------------------------------------------

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking
      and bankCode == "Scalable Capital Tagesgeld"
end

-- ---------------------------------------------------------------------------
-- InitializeSession
-- ---------------------------------------------------------------------------

function InitializeSession(protocol, bank, username, username2, password, interactive)
  connection = Connection()
  MM.printStatus("Verbinde mit Scalable Capital...")

  -- Schritt 1: GET /auth/login folgt der Auth0 Redirect-Kette automatisch
  local auth0html = connection:request("GET", AUTH_BASE .. "/login", nil, nil)

  -- Schritt 2: Auth0-Login-URL mit state ermitteln
  local auth0LoginUrl = connection:getBaseURL()

  if not auth0LoginUrl or not auth0LoginUrl:find("u/login") then
    -- Fallback: state direkt aus dem HTML extrahieren
    local state = auth0html:match("u/login%?state=([^&\"' \n\r]+)")
    if state then
      auth0LoginUrl = AUTH0_HOST .. "/u/login?state=" .. state
    else
      MM.printStatus("Fehler: Auth0-Login-URL nicht gefunden.")
      return LoginFailed
    end
  end

  -- Schritt 3: Credentials per POST an Auth0
  MM.printStatus("Sende Anmeldedaten...")
  local formBody = "username=" .. urlencode(username)
                .. "&password=" .. urlencode(password)
                .. "&action=default"

  connection:request("POST", auth0LoginUrl, formBody,
                     "application/x-www-form-urlencoded")

  -- Pruefe ob Login fehlgeschlagen (wir wuerden auf der Auth0-Seite bleiben)
  local afterPostUrl = connection:getBaseURL() or ""
  if afterPostUrl:find("u/login") then
    MM.printStatus("Fehler: Benutzername oder Passwort falsch.")
    return LoginFailed
  end

  -- Schritt 4: mfa-check Seite laden -> userId extrahieren
  -- Scalable nutzt Next.js App Router (seit ~05/2026): kein __NEXT_DATA__ mehr.
  -- Die userId erscheint im RSC-Streaming-Format als escaped JSON innerhalb eines
  -- <script>-Tags: \"userId\":\"o2So6X16...\" (Backslash-Quote statt reiner Quote).
  local mfaHtml = connection:request("GET", AUTH_BASE .. "/mfa-check", nil, nil)

  userId = nil

  -- Versuch 1: App Router RSC Format – escaped Quotes: \"userId\":\"...\"
  userId = mfaHtml:match("\\\"userId\\\":%s*\\\"([^\\\"]+)\\\"")

  if not userId then
    -- Versuch 2: Legacy __NEXT_DATA__ (Pages Router, fuer den Fall eines Rollbacks)
    local nextDataJson = mfaHtml:match(
      "<script id=\"__NEXT_DATA__\" type=\"application/json\">({.+})</script>")
    if nextDataJson then
      local ok, nd = pcall(function()
        return JSON(nextDataJson):dictionary()
      end)
      if ok and nd and nd["props"] and nd["props"]["pageProps"] then
        userId = nd["props"]["pageProps"]["userId"]
      end
    end
  end

  if not userId then
    -- Versuch 3: Unescaped Fallback (z.B. server-side rendered plain JSON)
    userId = mfaHtml:match("\"userId\"%s*:%s*\"([^\"]+)\"")
  end

  if not userId then
    MM.printStatus("Fehler: userId nicht gefunden.")
    return LoginFailed
  end

  LocalStorage.scalableUserId = userId

  -- Schritt 5: Push-Benachrichtigung ausloesen
  MM.printStatus("Sende Push-Benachrichtigung an Scalable App...")
  local startData = graphql(
    AUTH_GRAPHQL,
    "mutation start2faOnLogin($input: Start2faOnLoginInput!) {" ..
    "  start2faOnLogin(input: $input) { mfaSessionId __typename }" ..
    "}",
    {input = {userId = userId, deviceType = "Mac OS", deviceName = "MoneyMoney"}},
    "start2faOnLogin",
    AUTH_BASE .. "/mfa-check"
  )

  local mfaSessionId = nil
  if startData and startData["data"] and startData["data"]["start2faOnLogin"] then
    mfaSessionId = startData["data"]["start2faOnLogin"]["mfaSessionId"]
  end

  if not mfaSessionId then
    local errMsg = "unbekannt"
    if startData and startData["errors"] and startData["errors"][1] then
      errMsg = startData["errors"][1]["message"] or errMsg
    end
    MM.printStatus("Fehler: Push-Benachrichtigung konnte nicht ausgeloest werden. (" .. errMsg .. ")")
    return LoginFailed
  end

  -- Schritt 6: Auf App-Bestaetigung warten (max. 120 Sekunden, alle 2 s pollen)
  MM.printStatus("Bitte bestaetigen in der Scalable Capital App...")
  local mfaStatus = "PENDING"

  for i = 1, 60 do
    sleep(2)
    local validateData = graphql(
      AUTH_GRAPHQL,
      "mutation validate2faOnLogin($input: Validate2faOnLoginInput!) {" ..
      "  validate2faOnLogin(input: $input) { status __typename }" ..
      "}",
      {input = {userId = userId, mfaSessionId = mfaSessionId}},
      "validate2faOnLogin",
      AUTH_BASE .. "/mfa-check"
    )

    if validateData and validateData["data"] and validateData["data"]["validate2faOnLogin"] then
      mfaStatus = validateData["data"]["validate2faOnLogin"]["status"] or "PENDING"
    end

    if mfaStatus == "SUCCESS" then
      break
    end
  end

  if mfaStatus ~= "SUCCESS" then
    MM.printStatus("Fehler: 2FA-Bestaetigung fehlgeschlagen oder Zeitlimit.")
    return LoginFailed
  end

  MM.printStatus("Anmeldung erfolgreich!")
  return nil
end

-- ---------------------------------------------------------------------------
-- ListAccounts
-- ---------------------------------------------------------------------------

function ListAccounts(knownAccounts)
  if not userId then
    userId = LocalStorage.scalableUserId
  end
  if not userId then
    return {}
  end

  local data = graphql(
    COCKPIT_GRAPHQL,
    "query GetSavingsAccounts($id: ID!) { " ..
    "  account(id: $id) { " ..
    "    savingsAccounts { " ..
    "      id iban " ..
    "      personalizations { name } " ..
    "      ... on OvernightSavingsAccount { totalAmount interestRate } " ..
    "    } " ..
    "  } " ..
    "  personOverview(id: $id) { " ..
    "    personalDetails { firstName lastName } " ..
    "  } " ..
    "}",
    {id = userId},
    "GetSavingsAccounts"
  )

  local accounts = {}

  if not data or not data["data"] or not data["data"]["account"] then
    return accounts
  end

  -- Inhabername
  local ownerName = userId
  local po = data["data"]["personOverview"]
  if po and po["personalDetails"] then
    local pd = po["personalDetails"]
    ownerName = ((pd["firstName"] or "") .. " " .. (pd["lastName"] or "")):match("^%s*(.-)%s*$")
  end

  local savingsAccounts = data["data"]["account"]["savingsAccounts"] or {}

  for _, sa in ipairs(savingsAccounts) do
    local name = "Scalable Capital Tagesgeld"

    -- personalizations kann Objekt oder Array sein
    local pers = sa["personalizations"]
    if pers and type(pers) == "table" then
      local pname = pers["name"]
      if pname == nil and pers[1] then
        pname = pers[1]["name"]
      end
      if pname and pname ~= "" then
        name = pname
      end
    end

    table.insert(accounts, {
      name          = name,
      owner         = ownerName,
      accountNumber = sa["iban"] or sa["id"],  -- IBAN bevorzugt, intern ID als Fallback
      currency      = "EUR",
      type          = AccountTypeSavings,
    })
  end

  return accounts
end

-- ---------------------------------------------------------------------------
-- RefreshAccount
-- ---------------------------------------------------------------------------

function RefreshAccount(account, since)
  if not userId then
    userId = LocalStorage.scalableUserId
  end
  if not userId then
    return {balance = 0, transactions = {}}
  end

  -- Kontostand abrufen
  local data = graphql(
    COCKPIT_GRAPHQL,
    "query GetBalance($id: ID!) { " ..
    "  account(id: $id) { " ..
    "    savingsAccounts { " ..
    "      id iban " ..
    "      ... on OvernightSavingsAccount { totalAmount interestRate } " ..
    "    } " ..
    "  } " ..
    "}",
    {id = userId},
    "GetBalance"
  )

  local balance        = 0
  local interestRate   = nil
  -- savingsAccountId: interne UUID fuer den Transaktions-GraphQL-Endpoint.
  -- account.accountNumber ist die IBAN; die interne ID wird hier aufgeloest.
  local savingsAccountId = account.accountNumber

  if data and data["data"] and data["data"]["account"] then
    local savingsAccounts = data["data"]["account"]["savingsAccounts"] or {}
    for _, sa in ipairs(savingsAccounts) do
      -- Konto per IBAN oder interner ID identifizieren (beide Felder werden gespeichert)
      if sa["iban"] == account.accountNumber or sa["id"] == account.accountNumber then
        balance          = tonumber(sa["totalAmount"])  or 0
        interestRate     = tonumber(sa["interestRate"]) or nil
        savingsAccountId = sa["id"]
        break
      end
    end
  end

  if interestRate then
    print(string.format("Tagesgeld: %.2f EUR (%.2f %%)", balance, interestRate * 100))
  else
    print(string.format("Tagesgeld: %.2f EUR", balance))
  end

  -- Transaktionen abrufen
  local transactions = {}
  local txReferer = "https://de.scalable.capital/interest/" .. savingsAccountId .. "/"

  local txData = graphql(
    INTEREST_GRAPHQL,
    "query OvernightOverviewPageData($savingsAccountId: ID!, $accountId: ID!, $recentTransactionsInput: SavingsAccountCashTransactionInput!) {" ..
    "  account(id: $accountId) {" ..
    "    savingsAccount(id: $savingsAccountId) {" ..
    "      ... on OvernightSavingsAccount {" ..
    "        moreTransactions(input: $recentTransactionsInput) {" ..
    "          transactions {" ..
    "            id type status description amount currency" ..
    "            lastEventDateTime cashTransactionType" ..
    "          }" ..
    "        }" ..
    "      }" ..
    "    }" ..
    "  }" ..
    "}",
    {
      accountId               = userId,
      savingsAccountId        = savingsAccountId,
      recentTransactionsInput = {pageSize = 500},
    },
    "OvernightOverviewPageData",
    txReferer
  )

  if txData and txData["data"] and txData["data"]["account"] then
    local sa = txData["data"]["account"]["savingsAccount"]
    if sa and sa["moreTransactions"] and sa["moreTransactions"]["transactions"] then
      local txList = sa["moreTransactions"]["transactions"]

      -- Uebersetzungstabelle fuer cashTransactionType (API-Wert -> Anzeigename)
      local cashTypeLabel = {
        INTEREST          = "Zinsen",
        CASH_TRANSFER_IN  = "Einzahlung",
        CASH_TRANSFER_OUT = "Auszahlung",
        DEPOSIT           = "Einzahlung",
        WITHDRAWAL        = "Auszahlung",
        TAX               = "Steuern",
      }

      for _, tx in ipairs(txList) do
        -- bookingDate muss eine Zahl (Unix-Timestamp) sein, kein Datums-Table
        local ts = isoToTimestamp(tx["lastEventDateTime"])

        -- Nur Transaktionen ab 'since' einschliessen
        if not since or ts >= since then
          local amount   = tonumber(tx["amount"]) or 0
          local cashType = tx["cashTransactionType"] or tx["type"] or ""
          local label    = cashTypeLabel[cashType] or cashType

          -- Buchungstyp bestimmen und Vorzeichen korrigieren
          local txType = BookingTypeOther
          if cashType == "INTEREST"
          or cashType == "CASH_TRANSFER_IN"
          or cashType == "DEPOSIT" then
            txType = BookingTypeCredit
          elseif cashType == "CASH_TRANSFER_OUT"
              or cashType == "WITHDRAWAL" then
            txType = BookingTypeDebit
            if amount > 0 then amount = -amount end
          elseif amount >= 0 then
            txType = BookingTypeCredit
          else
            txType = BookingTypeDebit
          end

          table.insert(transactions, {
            bookingDate = ts,
            valueDate   = ts,
            amount      = amount,
            currency    = tx["currency"] or "EUR",
            name        = label,
            purpose     = tx["description"] or "",
            bookingText = label,
            type        = txType,
          })
        end
      end
    end
  end

  return {
    balance      = balance,
    transactions = transactions,
  }
end

-- ---------------------------------------------------------------------------
-- EndSession
-- ---------------------------------------------------------------------------

function EndSession()
  MM.printStatus("Abmelden...")
  pcall(function()
    connection:request("GET", AUTH_BASE .. "/logout", nil, nil)
  end)
end
