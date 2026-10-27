#!/usr/bin/env node
// CIP-0103 third-party interop harness: drives the OpenZeppelin CIP-0112
// registry (`openzeppelin-token-cip112-v1` of `OpenZeppelin/canton-contracts`)
// through the Canton Wallet Gateway's CIP-0103 APIs.
//
// The wallet user is an externally-signed party created and held by the
// gateway (built-in `wallet-kernel` Ed25519 signing driver). Every wallet-side
// ledger action goes through the gateway's CIP-0103 dApp JSON-RPC API;
// transaction approval uses the gateway's user JSON-RPC API (`sign` +
// `execute`), i.e. the same calls the gateway's own approve UI makes. No
// direct Ledger API access is used for the wallet party anywhere in this file.
//
// Every wallet-side action is a Token Standard V2 choice: accept the registry's
// mint offer, allocate through its factory with the rules contract disclosed,
// and accept the dApp's request. Interactive submission prepares one command
// per transaction, so the last two are separate prepareExecute calls.
//
// CIP-0103 dApp API coverage: connect, isConnected, status, getActiveNetwork,
// listAccounts, getPrimaryAccount, signMessage, prepareExecute (incl. the
// async-variant userUrl, disclosed contracts, and a failed-command path),
// ledgerApi, txChanged, disconnect.
//
// Subcommands (orchestrated by scripts/wallet-gateway-cip0103-interop.sh):
//   create-wallet      create session + externally-signed wallet party
//   dapp-flow          connect, accept the mint offer, allocate + accept the request
//   verify-wallet-view assert the wallet's post-settlement projection
//
// Scope: experimental interoperability validation. The harness makes no
// conformance or production claim.

import { createPublicKey, verify as cryptoVerify } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

const GATEWAY = process.env.OZ_GATEWAY_URL ?? 'http://127.0.0.1:3030'
const USER_API = `${GATEWAY}/api/v0/user`
const DAPP_API = `${GATEWAY}/api/v0/dapp`
const JSON_API = process.env.OZ_JSON_API_URL ?? 'http://127.0.0.1:3975'
const NETWORK_ID = process.env.OZ_GATEWAY_NETWORK_ID ?? 'canton:localnet'
const WORK_DIR = process.env.OZ_INTEROP_WORK_DIR ?? '.cache/wallet-gateway-interop'
// The gateway keys a session by the origin of the dApp that opens it. This dApp
// runs headless, so it declares a stable origin of its own.
const DAPP_ORIGIN = process.env.OZ_DAPP_ORIGIN ?? 'http://oz-cip0103-interop.localhost'
const LEDGER_USER = process.env.OZ_GATEWAY_LEDGER_USER ?? 'oz-cip0103-interop'
const EXTERNAL = process.env.OZ_USE_EXTERNAL_LEDGER === '1'
// The admin token of the participant: it provisions the gateway's ledger user,
// and it reads the registry's rules contract as the admin party for the
// disclosure that the wallet's allocation needs. A participant without
// authentication needs no token.
const ADMIN_TOKEN = process.env.OZ_LEDGER_TOKEN_FILE
  ? readFileSync(process.env.OZ_LEDGER_TOKEN_FILE, 'utf8').trim()
  : null

const PKG_INTEROP = '#openzeppelin-experimental-cip-interop-exemplar'
const PKG_TOKEN = '#openzeppelin-token-cip112-v1'
const MOD_WALLET = 'OpenZeppelin.Experimental.Interop.Cip0103Wallet'
// The two templates that the dApp side creates or discloses, and the Token
// Standard V2 interfaces, which are the wallet's whole surface: it never
// names a template of the registry.
const T = {
  rules: `${PKG_TOKEN}:OpenZeppelin.Token.Cip112.V1.Registry:TokenRules`,
  appRequest: `${PKG_INTEROP}:${MOD_WALLET}:AppAllocationRequest`,
  holding: '#splice-api-token-holding-v2:Splice.Api.Token.HoldingV2:Holding',
  transferInstruction: '#splice-api-token-transfer-instruction-v2:Splice.Api.Token.TransferInstructionV2:TransferInstruction',
  allocationFactory: '#splice-api-token-allocation-instruction-v2:Splice.Api.Token.AllocationInstructionV2:AllocationFactory',
  allocation: '#splice-api-token-allocation-v2:Splice.Api.Token.AllocationV2:Allocation',
  settlementFactory: '#splice-api-token-allocation-v2:Splice.Api.Token.AllocationV2:SettlementFactory',
  allocationRequest: '#splice-api-token-allocation-request-v2:Splice.Api.Token.AllocationRequestV2:AllocationRequest',
  eventLog: '#splice-api-token-transfer-events-v2:Splice.Api.Token.TransferEventsV2:EventLog',
}

let rpcId = 0
const log = (...args) => console.log('[harness]', ...args)
const secretField = /access.?token|authorization|client.?secret|password|signature/i

function redactSecrets(value) {
  if (Array.isArray(value)) return value.map(redactSecrets)
  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value).map(([key, nested]) => [
        key,
        secretField.test(key) ? '[REDACTED]' : redactSecrets(nested),
      ])
    )
  }
  return value
}

const safeJson = (value) => JSON.stringify(redactSecrets(value))

// Evidence-safe form of a gateway userUrl: origin + path only, since the
// query string may embed session tokens.
const withoutQuery = (url) => {
  try {
    const u = new URL(url)
    return u.origin + u.pathname
  } catch {
    return '[unparseable-url]'
  }
}

// Verify an Ed25519 signature (base64 signature, base64 raw 32-byte public
// key) over the UTF-8 message bytes.
function verifyEd25519(publicKeyB64, message, signatureB64) {
  const raw = Buffer.from(publicKeyB64, 'base64')
  if (raw.length !== 32) throw new Error(`unexpected Ed25519 public key length ${raw.length}`)
  const spki = Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), raw])
  const key = createPublicKey({ key: spki, format: 'der', type: 'spki' })
  return cryptoVerify(null, Buffer.from(message, 'utf8'), key, Buffer.from(signatureB64, 'base64'))
}

function fail(msg) {
  console.error('[harness] FAIL:', msg)
  process.exit(1)
}

async function rpc(url, method, params, token) {
  const headers = { 'content-type': 'application/json' }
  if (token) headers.authorization = `Bearer ${token}`
  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify({ jsonrpc: '2.0', id: `oz-${++rpcId}`, method, params }),
  })
  const text = await res.text()
  let body
  try {
    body = JSON.parse(text)
  } catch {
    throw new Error(`${method}: non-JSON response (HTTP ${res.status}): ${text.slice(0, 500)}`)
  }
  if (body.error) {
    // Surface the CIP-0103 ProviderRpcError shape ({ message, code, data? })
    // so callers can match on the standardized code, not the message text.
    const err = new Error(`${method}: JSON-RPC error ${body.error.code}: ${body.error.message} ${JSON.stringify(body.error.data ?? '')}`)
    err.code = body.error.code
    err.data = body.error.data
    throw err
  }
  return body.result
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function poll(desc, timeoutMs, intervalMs, fn) {
  const deadline = Date.now() + timeoutMs
  let lastErr
  while (Date.now() < deadline) {
    try {
      const value = await fn()
      if (value !== undefined && value !== null && value !== false) return value
    } catch (err) {
      lastErr = err
    }
    await sleep(intervalMs)
  }
  throw new Error(`timeout waiting for ${desc}${lastErr ? `: last error: ${lastErr.message}` : ''}`)
}

function readJson(name) {
  return JSON.parse(readFileSync(join(WORK_DIR, name), 'utf8'))
}

function writeJson(name, value) {
  mkdirSync(WORK_DIR, { recursive: true })
  writeFileSync(join(WORK_DIR, name), JSON.stringify(value, null, 2))
  log(`wrote ${join(WORK_DIR, name)}`)
}

// --- gateway ledgerApi passthrough (the CIP-0103 read surface) --------------

async function ledgerApi(token, requestMethod, resource, body) {
  return rpc(DAPP_API, 'ledgerApi', { requestMethod, resource, ...(body ? { body } : {}) }, token)
}

// Active contracts of one Token Standard interface, with their views: what a
// wallet reads, whatever template the registry uses underneath.
const acsInterfaceRequest = (party, interfaceId, activeAtOffset) => ({
  filter: {
    filtersByParty: {
      [party]: {
        cumulative: [{ identifierFilter: { InterfaceFilter: { value: { interfaceId, includeInterfaceView: true, includeCreatedEventBlob: false } } } }],
      },
    },
  },
  verbose: false,
  activeAtOffset,
})

// Active contracts of one template, with the created-event blob that lets the
// reader give the contract to another party as a disclosed contract.
const acsTemplateRequest = (party, templateId, activeAtOffset) => ({
  filter: {
    filtersByParty: {
      [party]: {
        cumulative: [{ identifierFilter: { TemplateFilter: { value: { templateId, includeCreatedEventBlob: true } } } }],
      },
    },
  },
  verbose: false,
  activeAtOffset,
})

// The transactions that `party` sees since `beginExclusive`, as ledger
// effects, restricted to the exercises of one interface's choices. This is
// how a wallet reads the standard `EventLog_HoldingsChange` events.
const updatesRequest = (party, interfaceId, beginExclusive, endInclusive) => ({
  beginExclusive,
  endInclusive,
  updateFormat: {
    includeTransactions: {
      eventFormat: {
        filtersByParty: {
          [party]: {
            cumulative: [{ identifierFilter: { InterfaceFilter: { value: { interfaceId, includeInterfaceView: false, includeCreatedEventBlob: false } } } }],
          },
        },
        verbose: false,
      },
      transactionShape: 'TRANSACTION_SHAPE_LEDGER_EFFECTS',
    },
  },
  verbose: false,
})

// Parse a /v2/state/active-contracts response. Fails loudly on schema drift:
// a non-empty response none of whose entries parse means the pinned
// gateway/ledger schema changed, and returning [] would surface only as an
// opaque downstream poll timeout.
function parseActiveContracts(res) {
  const items = Array.isArray(res) ? res : Array.isArray(res?.body) ? res.body : null
  if (items === null) {
    throw new Error(`active-contracts: unrecognized response shape: ${JSON.stringify(res).slice(0, 400)}`)
  }
  const contracts = []
  for (const item of items) {
    const entry = item?.contractEntry?.JsActiveContract ?? item?.contractEntry?.activeContract
    const ev = entry?.createdEvent
    if (ev) {
      contracts.push({
        contractId: ev.contractId,
        templateId: ev.templateId,
        view: ev.interfaceViews?.[0]?.viewValue,
        payload: ev.createArgument ?? ev.createArguments,
        createdEventBlob: ev.createdEventBlob,
        synchronizerId: entry.synchronizerId,
      })
    }
  }
  if (items.length > 0 && contracts.length === 0) {
    throw new Error(`active-contracts: ${items.length} entries but none parseable; first: ${JSON.stringify(items[0]).slice(0, 400)}`)
  }
  return contracts
}

// Parse a /v2/updates/flats response into the `EventLog_HoldingsChange`
// events it carries: one per exercise of that choice, with the argument that
// names the account, the holdings, and the settled leg sides.
function parseHoldingsChanges(res) {
  const updates = Array.isArray(res) ? res : Array.isArray(res?.body) ? res.body : null
  if (updates === null) {
    throw new Error(`updates: unrecognized response shape: ${JSON.stringify(res).slice(0, 400)}`)
  }
  const events = []
  for (const update of updates) {
    const tx = update?.update?.Transaction?.value
    for (const event of tx?.events ?? []) {
      const ex = event?.ExercisedEvent
      if (ex?.choice === 'EventLog_HoldingsChange' && String(ex.interfaceId ?? '').endsWith('TransferEventsV2:EventLog')) {
        events.push({ updateId: tx.updateId, ...ex.choiceArgument })
      }
    }
  }
  return events
}

// Shared holding arithmetic over `Holding` interface views (from either ACS path).
const isUnlocked = (h) => !h.view?.lock
const unlockedBalance = (hs) => hs.filter(isUnlocked).reduce((acc, h) => acc + Number(h.view?.amount ?? 0), 0)
const unlockedUsd = (hs) => hs.filter((h) => isUnlocked(h) && h.view?.instrumentId?.id === 'USD')
const balanceOf = (hs, party) =>
  unlockedUsd(hs).filter((h) => h.view?.account?.owner === party).reduce((a, h) => a + Number(h.view.amount), 0)
const supplyOf = (hs) => hs.filter((h) => h.view?.instrumentId?.id === 'USD').reduce((a, h) => a + Number(h.view.amount), 0)

// Query the wallet party's active contracts of one interface via the gateway. In other words: for this interface, what contracts does the party see/own?
async function acs(token, party, interfaceId) {
  const offset = await ledgerEnd(token)
  return parseActiveContracts(await ledgerApi(token, 'post', '/v2/state/active-contracts', acsInterfaceRequest(party, interfaceId, offset)))
}

async function ledgerEnd(token) {
  const end = await ledgerApi(token, 'get', '/v2/state/ledger-end')
  const offset = end?.offset ?? end?.body?.offset
  if (offset === undefined) throw new Error(`ledger-end gave no offset: ${JSON.stringify(end)}`)
  return offset
}

// The `EventLog_HoldingsChange` events that the wallet party saw since
// `beginExclusive`, read through the gateway.
async function holdingsChanges(token, party, beginExclusive) {
  const endInclusive = await ledgerEnd(token)
  if (endInclusive <= beginExclusive) return []
  return parseHoldingsChanges(
    await ledgerApi(token, 'post', '/v2/updates/flats', updatesRequest(party, T.eventLog, beginExclusive, endInclusive))
  )
}

// --- dApp command submission + user-side approval ----------------------------

// Sign and execute a pending transaction through the user API - the same
// calls the gateway's own approve page makes.
async function approveTransaction(token, party, tx) {
  log(`sign transaction ${tx.id}`)
  const signed = await rpc(USER_API, 'sign', { transactionId: tx.id, partyId: party }, token)
  if (signed.status !== 'signed') {
    throw new Error(`sign returned status ${signed.status}: ${safeJson(signed)}`)
  }
  log(`execute transaction ${tx.id}`)
  await rpc(
    USER_API,
    'execute',
    { signature: signed.signature, signedBy: signed.signedBy, transactionId: tx.id, partyId: party },
    token
  )
}

const prepareExecuteUserUrls = []

// Exercise one choice through CIP-0103 prepareExecute, with the disclosed
// contracts that the choice reads, and approve the prepared transaction
// through the user API.
async function exerciseViaGateway(token, party, label, templateId, contractId, choice, choiceArgument, disclosedContracts = []) {
  const commandId = `oz-cip0103-interop-${label}`
  log(`prepareExecute ${choice} (commandId=${commandId}, ${disclosedContracts.length} disclosed contract(s))`)
  const prepared = await rpc( // Demonstrates the use of CIP103 prepareExecute, which prepares, signs and executes a command.
    DAPP_API,
    'prepareExecute',
    {
      commandId,
      commands: [{ ExerciseCommand: { templateId, contractId, choice, choiceArgument } }],
      disclosedContracts,
    },
    token
  )
  // Async dApp API: prepareExecute MUST return a userUrl pointing the user to
  // the wallet's review facility.
  if (typeof prepared?.userUrl !== 'string' || prepared.userUrl.length === 0) {
    throw new Error(`prepareExecute returned no userUrl: ${safeJson(prepared)}`)
  }
  prepareExecuteUserUrls.push(withoutQuery(prepared.userUrl))

  // The remote gateway parks the prepared transaction for user approval.
  // Approve it programmatically through the user API, exactly as the
  // gateway's own approve page does: sign, then execute.
  const tx = await poll(`pending transaction ${commandId}`, 30_000, 300, async () => {
    const { transactions } = await rpc(USER_API, 'listTransactions', {}, token)
    return transactions.find((t) => t.commandId === commandId && t.status === 'pending')
  })
  await approveTransaction(token, party, tx)
  const done = await poll(`transaction ${commandId} executed`, 30_000, 300, async () => {
    const transaction = await rpc(USER_API, 'getTransaction', { transactionId: tx.id }, token)
    if (transaction.status === 'failed') throw new Error(`transaction failed: ${JSON.stringify(transaction)}`)
    return transaction.status === 'executed' ? transaction : undefined
  })
  log(`executed ${choice} (transaction ${done.id})`)
  return done
}

// CIP-0103 signMessage (async variant): the dApp requests the signature and
// gets { messageId, userUrl }; the user approves through the user API, which
// returns { signature, publicKey }. The same calls the gateway's approve UI
// makes, mirroring the transaction path above.
async function signMessageViaGateway(token, party, message) {
  const requested = await rpc(DAPP_API, 'signMessage', { message }, token)
  if (!requested?.messageId || typeof requested.userUrl !== 'string' || requested.userUrl.length === 0) {
    throw new Error(`signMessage returned no messageId/userUrl: ${safeJson(requested)}`)
  }
  const signed = await rpc(USER_API, 'signMessage', { messageId: requested.messageId, partyId: party }, token)
  if (!signed?.signature || !signed?.publicKey) {
    throw new Error(`user signMessage returned no signature/publicKey: ${safeJson(signed)}`)
  }
  return { messageId: requested.messageId, userUrl: withoutQuery(requested.userUrl), signature: signed.signature, publicKey: signed.publicKey }
}

// CIP-0103 error code exemplified by the doomed command below: the CIP's
// error table adopts EIP-1474, whose -32603 is "Internal error". Gateway
// 1.8.1 maps a prepare-time interpretation failure (consumed contract) to
// this code, with the Canton CONTRACT_NOT_FOUND detail in `data`.
const CIP0103_INTERNAL_ERROR = -32603

// CIP-0103 standardized errors: a doomed command (re-accepting the consumed
// mint offer) must surface either as a ProviderRpcError with a code from the
// CIP-0103 error table at prepare time, or as a failed transaction on the
// lifecycle the wallet observes. Anything else (silent success, a non-table
// code) fails the gate.
async function expectFailedTx(token, party, consumedOfferCid) { // Exemplifies receiving a standardized error, in this case -32603	Internal error. 
  const commandId = 'oz-cip0103-interop-doomed'
  log(`prepareExecute doomed re-accept of consumed mint offer (commandId=${commandId})`)
  try {
    await rpc(
      DAPP_API,
      'prepareExecute',
      {
        commandId,
        commands: [{ ExerciseCommand: { templateId: T.transferInstruction, contractId: consumedOfferCid, choice: 'TransferInstruction_Accept', choiceArgument: { actors: [party], extraArgs: EXTRA_ARGS } } }],
      },
      token
    )
  } catch (err) {
    if (typeof err.code !== 'number') throw err // transport failure, not a provider error
    if (err.code !== CIP0103_INTERNAL_ERROR) {
      throw new Error(`doomed command failed with code ${err.code}, expected CIP-0103 ${CIP0103_INTERNAL_ERROR} (Internal error): ${err.message}`)
    }
    log(`doomed command rejected at prepare with CIP-0103 error ${err.code} (Internal error, EIP-1474 table)`)
    return { path: 'rpc-error', cip0103Code: err.code, error: err.message }
  }
  // Prepare parked the transaction: approve it; execution against a consumed
  // contract must transition it to failed.
  const failed = await poll(`doomed transaction ${commandId} failed`, 30_000, 300, async () => {
    const { transactions } = await rpc(USER_API, 'listTransactions', {}, token)
    const tx = transactions.find((t) => t.commandId === commandId)
    if (!tx) return undefined
    if (tx.status === 'failed') return tx
    if (tx.status === 'pending') {
      await approveTransaction(token, party, tx).catch((err) => log(`doomed approval rejected: ${err.message}`))
    }
    return undefined
  })
  log(`doomed transaction failed as expected (${failed.id})`)
  return { path: 'tx-failed', transactionId: failed.id }
}

// --- txChanged SSE listener (CIP-0103 event surface) -------------------------

function listenTxChanged(token) {
  const events = []
  const controller = new AbortController()
  const url = `${DAPP_API}/events?token=${encodeURIComponent(token)}`
  const done = (async () => {
    try {
      const res = await fetch(url, {
        headers: { accept: 'text/event-stream' },
        signal: controller.signal,
      })
      if (!res.ok || !res.body) throw new Error(`SSE connect failed: HTTP ${res.status}`)
      const reader = res.body.getReader()
      const decoder = new TextDecoder()
      let buf = ''
      for (;;) {
        const { value, done: eof } = await reader.read()
        if (eof) break
        buf += decoder.decode(value, { stream: true })
        let idx
        while ((idx = buf.indexOf('\n\n')) >= 0) {
          const frame = buf.slice(0, idx)
          buf = buf.slice(idx + 2)
          const eventLine = frame.split('\n').find((l) => l.startsWith('event:'))
          const dataLine = frame.split('\n').find((l) => l.startsWith('data:'))
          if (!dataLine) continue
          const eventName = eventLine ? eventLine.slice(6).trim() : 'message'
          try {
            events.push({ event: eventName, data: JSON.parse(dataLine.slice(5).trim()) })
          } catch {
            events.push({ event: eventName, data: dataLine.slice(5).trim() })
          }
        }
      }
    } catch (err) {
      if (err.name !== 'AbortError') log(`SSE listener ended: ${err.message}`)
    }
  })()
  return {
    events,
    stop: async () => {
      controller.abort()
      await done.catch(() => {})
    },
  }
}

// --- external mode: operator-side phases over the JSON Ledger API -----------
//
// On managed devnet/testnet validators (e.g. ChainSafe dev1) only the JSON
// Ledger API is exposed - there is no gRPC endpoint for `dpm script` to use.
// In external mode the operator-side phases (setup / settle / verify) are
// therefore driven directly against the JSON Ledger API as the operator
// party. In every mode the operator also reads the registry's rules contract
// with its created-event blob here, which the wallet's allocation carries as a
// disclosed contract (a production registry serves it from its off-ledger
// API). These values MUST mirror the Daml module's deterministic constants
// (`gatewayRef`, `gatewaySettlement`, `gatewayLeg`, `gatewayWalletSpec`,
// amounts): the wallet allocates against the request that the setup phase
// emitted, and the settle batch compares the settlement and legs for equality.

const REF = 'cip0103-wallet-gateway-interop'
const META = { values: {} }
// The `ExtraArgs` of the Splice token metadata API: an empty choice context and
// empty metadata.
const EXTRA_ARGS = { context: { values: {} }, meta: META }
const MINT = '40.0'
const TRANSFER = '25.0'
const acct = (p) => ({ owner: p, provider: null, id: '' })
const settlementInfo = (op) => ({ executors: [op], id: REF, cid: null, meta: META })
const transferLeg = (wallet, op) => ({
  transferLegId: `${REF}-leg`,
  sender: acct(wallet),
  receiver: acct(op),
  amount: TRANSFER,
  instrumentId: 'USD',
  meta: META,
})
const legSide = (side, leg) => ({
  transferLegId: leg.transferLegId,
  side,
  otherside: side === 'SenderSide' ? leg.receiver : leg.sender,
  amount: leg.amount,
  instrumentId: leg.instrumentId,
  meta: leg.meta,
})
// An uncommitted allocation with no settlement deadline: the gateway flow runs
// on wallclock time.
const allocationSpec = (admin, authorizer, sides) => ({
  admin,
  authorizer,
  transferLegSides: sides,
  settlementDeadline: null,
  nextIterationFunding: null,
  committed: false,
  meta: META,
})
const walletSpec = (op, wallet) => allocationSpec(op, acct(wallet), [legSide('SenderSide', transferLeg(wallet, op))])
// The registry's storage bounds, as the Daml `registryConfig`: a day for a
// workflow, an hour of lock grace. A `RelTime` is given in microseconds.
const registryConfig = (admin) => ({
  admin,
  maxTTL: { microseconds: String(24 * 3600 * 1_000_000) },
  lockGrace: { microseconds: String(3600 * 1_000_000) },
})
const isoNow = () => new Date().toISOString()
const isoInAnHour = () => new Date(Date.now() + 3600 * 1000).toISOString()

async function jsonApiDirect(token, method, path, body) {
  const res = await fetch(`${JSON_API}${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  })
  const text = await res.text()
  if (!res.ok) throw new Error(`${method} ${path}: HTTP ${res.status}: ${text.slice(0, 500)}`)
  return text ? JSON.parse(text) : undefined
}

let extCmd = 0
async function submitAndWait(token, actAs, label, commands) {
  const commandId = `oz-cip0103-external-${label}-${++extCmd}`
  log(`submit ${label} (as ${actAs.slice(0, 24)}...)`)
  const res = await jsonApiDirect(token, 'POST', '/v2/commands/submit-and-wait-for-transaction', {
    commands: { commands, commandId, actAs: [actAs] },
  })
  const events = res?.transaction?.events ?? []
  const created = []
  for (const e of events) {
    const ev = e?.CreatedEvent ?? e?.created ?? e?.CreatedTreeEvent?.value
    if (ev) created.push({ contractId: ev.contractId, templateId: ev.templateId, payload: ev.createArgument ?? ev.createArguments })
  }
  return { created, updateId: res?.transaction?.updateId }
}

const createdOf = (result, entity) => {
  const hit = result.created.find((c) => c.templateId?.endsWith(`:${entity}`))
  if (!hit) throw new Error(`no created ${entity} in transaction; created: ${result.created.map((c) => c.templateId).join(', ')}`)
  return hit.contractId
}

async function ledgerEndDirect(token) {
  const end = await jsonApiDirect(token, 'GET', '/v2/state/ledger-end')
  return end.offset
}

// Direct ACS reads as the operator (the wallet's reads go through the gateway
// ledgerApi instead - that is the surface under test; this one is plumbing).
async function acsDirect(token, party, interfaceId) {
  const offset = await ledgerEndDirect(token)
  return parseActiveContracts(await jsonApiDirect(token, 'POST', '/v2/state/active-contracts', acsInterfaceRequest(party, interfaceId, offset)))
}

// The registry's rules contract as a disclosed contract, read as the admin.
async function rulesDisclosure(token, admin, rulesCid) {
  const offset = await ledgerEndDirect(token)
  const rules = parseActiveContracts(await jsonApiDirect(token, 'POST', '/v2/state/active-contracts', acsTemplateRequest(admin, T.rules, offset)))
  const hit = rules.find((c) => c.contractId === rulesCid)
  if (!hit?.createdEventBlob) throw new Error(`rules contract ${rulesCid} not found with its created-event blob`)
  return { templateId: hit.templateId, contractId: hit.contractId, createdEventBlob: hit.createdEventBlob, synchronizerId: hit.synchronizerId }
}

async function operatorContext() {
  const { partyId: wallet } = readJson('wallet.json')
  const operator = process.env.OZ_LEDGER_OPERATOR_PARTY
  const token = await oidcToken()
  return { wallet, operator, token }
}

async function setupExternal() { // Function used for setting up the necessary ledger state.
  const { wallet, operator: op, token } = await operatorContext()
  const now = isoNow()

  // Baselines for delta-based verification on a reused ledger.
  const holdings = await acsDirect(token, op, T.holding) // Read the holdings the operator sees: its own, and the wallet's, which it co-signs as the admin.
  const baselineWalletBalance = balanceOf(holdings, wallet)
  const baselineReceiverBalance = balanceOf(holdings, op)
  const baselineSupply = supplyOf(holdings)
  const baselineOffset = await ledgerEndDirect(token)
  log(`baselines: wallet=${baselineWalletBalance} receiver=${baselineReceiverBalance} supply=${baselineSupply} offset=${baselineOffset}`)

  // The registry: one rules contract, signed by the operator as its admin.
  const rules = await submitAndWait(token, op, 'rules', [
    { CreateCommand: { templateId: T.rules, createArguments: { config: registryConfig(op) } } },
  ])
  const rulesCid = createdOf(rules, 'TokenRules')

  // The dApp's CIP-0103 request toward the wallet: its sender side of the leg.
  const request = await submitAndWait(token, op, 'request', [
    { CreateCommand: { templateId: T.appRequest, createArguments: {
      settlement: settlementInfo(op),
      allocations: [walletSpec(op, wallet)],
      requestedAt: now,
      settleAt: null,
    } } },
  ])
  const requestCid = createdOf(request, 'AppAllocationRequest')

  // The wallet's funding: the registry's two-step mint, which the wallet accepts through the gateway.
  const mintOffer = await submitAndWait(token, op, 'mint-offer', [
    { ExerciseCommand: { templateId: T.rules, contractId: rulesCid, choice: 'TokenRules_OfferMint', choiceArgument: {
      receiver: acct(wallet),
      instrumentId: 'USD',
      amount: MINT,
      requestedAt: now,
      executeBefore: isoInAnHour(),
      reason: 'gateway interop mint',
    } } },
  ])
  const mintOfferCid = createdOf(mintOffer, 'TokenTransferInstruction')

  // The receiver's side, allocated through the standard factory. The operator
  // is the admin, so its own submission needs no disclosure.
  const leg = transferLeg(wallet, op)
  const allocated = await submitAndWait(token, op, 'receiver-allocation', [
    { ExerciseCommand: { templateId: T.allocationFactory, contractId: rulesCid, choice: 'AllocationFactory_Allocate', choiceArgument: {
      settlement: settlementInfo(op),
      allocation: allocationSpec(op, acct(op), [legSide('ReceiverSide', leg)]),
      requestedAt: now,
      inputHoldingCids: [],
      extraArgs: EXTRA_ARGS,
      actors: [op],
    } } },
  ])
  const receiverAllocationCid = createdOf(allocated, 'TokenAllocation')

  writeJson('setup-output.json', { // This function ends, having created the registry, the request toward the wallet, the mint offer, and the receiver's allocation.
    admin: op, app: op, receiver: op, rulesCid, requestCid, mintOfferCid, receiverAllocationCid,
    baselineWalletBalance, baselineReceiverBalance, baselineSupply, baselineOffset,
  })
  log('external setup complete')
}

async function settleExternal() { // Function used to call batch settle, by the operator.
  const { wallet, operator: op, token } = await operatorContext()
  const setup = readJson('setup-output.json')
  const { walletAllocationCid } = readJson('gateway-output.json')
  const result = await submitAndWait(token, op, 'settle', [
    { ExerciseCommand: { templateId: T.settlementFactory, contractId: setup.rulesCid, choice: 'SettlementFactory_SettleBatch', choiceArgument: {
      settlement: settlementInfo(op),
      transferLegs: [transferLeg(wallet, op)],
      allocations: [walletAllocationCid, setup.receiverAllocationCid].map((allocationCid) => ({
        allocationCid, extraTransferLegSides: [], nextIterationFunding: null,
      })),
      actors: [op],
      extraArgs: EXTRA_ARGS,
    } } },
  ])
  // The settlement pays the receiver's leg out as a new holding.
  const holdings = result.created.filter((c) => c.templateId?.endsWith(':TokenHolding'))
  if (holdings.length < 1) fail(`expected the receiver's holding from SettleBatch, saw ${result.created.length} created contract(s)`)
  log(`settled batch (updateId ${result.updateId})`)
}

async function verifyExternal() { // Should be ran post-settlement. Reads the holdings the operator sees and the settlement's events, and asserts the deltas: wallet +15, receiver (operator) +25, supply +40.
  const { wallet, operator: op, token } = await operatorContext()
  const setup = readJson('setup-output.json')
  const holdings = await acsDirect(token, op, T.holding)

  const receiverDelta = balanceOf(holdings, op) - setup.baselineReceiverBalance
  if (Math.abs(receiverDelta - 25) > 1e-9) fail(`receiver balance delta ${receiverDelta}, expected +25`)
  const walletDelta = balanceOf(holdings, wallet) - setup.baselineWalletBalance
  if (Math.abs(walletDelta - 15) > 1e-9) fail(`wallet balance delta ${walletDelta}, expected +15`)
  const supplyDelta = supplyOf(holdings) - setup.baselineSupply
  if (Math.abs(supplyDelta - 40) > 1e-9) fail(`supply delta ${supplyDelta}, expected +40`)

  const endInclusive = await ledgerEndDirect(token)
  const events = parseHoldingsChanges(
    await jsonApiDirect(token, 'POST', '/v2/updates/flats', updatesRequest(op, T.eventLog, setup.baselineOffset, endInclusive))
  )
  const settled = events.filter((e) => (e.transferLegSides ?? []).some((s) => s.transferLegId === `${REF}-leg`))
  if (settled.length < 2) fail(`expected the settlement's holdings-change events for both accounts, saw ${settled.length}`)
  log(`operator verification passed: receiver +25, wallet +15, supply +40, ${settled.length} settlement event(s) of ${events.length} holdings-change event(s)`)
}

// --- subcommands -------------------------------------------------------------

// Provision the gateway's ledger user on the participant. This is admin-side
// IAM provisioning, NOT part of the wallet surface under test; on a real
// network the validator operator does this. The user starts without rights:
// the gateway grants it the wallet party's rights when it allocates that party.
// The request carries the participant's admin token, which the LocalNet gate
// mints; an unauthenticated participant needs no token.
async function provisionLedgerUser(userId) {
  const res = await fetch(`${JSON_API}/v2/users`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      ...(ADMIN_TOKEN ? { authorization: `Bearer ${ADMIN_TOKEN}` } : {}),
    },
    body: JSON.stringify({
      user: { id: userId, primaryParty: '', isDeactivated: false, identityProviderId: '' },
      rights: [],
    }),
  })
  if (res.ok) {
    log(`provisioned ledger user ${userId}`)
    return
  }
  const text = await res.text()
  if (res.status === 409 || text.includes('ALREADY_EXISTS')) {
    log(`ledger user ${userId} already exists`)
    return
  }
  throw new Error(`failed to create ledger user ${userId}: HTTP ${res.status}: ${text.slice(0, 400)}`)
}

// External mode (devnet/testnet): mint a real OIDC access token with the
// client-credentials grant. All identifiers and secrets come from the
// environment - nothing network-specific lives in the repo.
async function oidcToken() {
  const res = await fetch(process.env.OZ_OIDC_TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'client_credentials',
      client_id: process.env.OZ_OIDC_CLIENT_ID,
      client_secret: process.env.OZ_OIDC_CLIENT_SECRET,
      audience: process.env.OZ_OIDC_AUDIENCE,
    }),
  })
  if (!res.ok) throw new Error(`OIDC token request failed: HTTP ${res.status}`)
  const { access_token: accessToken } = await res.json()
  if (!accessToken) throw new Error('OIDC token response carried no access_token')
  return accessToken
}

// The token that reads the registry's rules contract as the admin party: the
// operator's OIDC token in external mode, the participant's admin token on
// LocalNet, and none on the sandbox, which authenticates nothing.
async function dappLedgerToken() {
  return EXTERNAL ? oidcToken() : ADMIN_TOKEN
}

// External mode: the runner cannot allocate parties, so instead of
// createWallet (which allocates an externally-signed party) the gateway
// ADOPTS the pre-allocated participant-local party the token can act as:
// addSession auto-syncs the user's ledger parties into gateway wallets with
// the `participant` signing provider, and the flow proceeds through the same
// CIP-0103 surfaces with participant-side signing.
async function createWalletExternal() {
  const partyId = process.env.OZ_LEDGER_PARTY
  const operator = process.env.OZ_LEDGER_OPERATOR_PARTY
  if (!partyId || !operator) fail('external mode requires OZ_LEDGER_PARTY and OZ_LEDGER_OPERATOR_PARTY')
  log(`user API: ${USER_API}, network: ${NETWORK_ID} (external ledger)`)
  const accessToken = await oidcToken()
  log('obtained OIDC access token (client_credentials)')
  await rpc(USER_API, 'addSession', { networkId: NETWORK_ID, origin: DAPP_ORIGIN }, accessToken)
  log('session added')
  await rpc(USER_API, 'syncWallets', undefined, accessToken).catch((err) => log(`syncWallets: ${err.message}`))
  const wallet = await poll(`gateway wallet for ${partyId}`, 60_000, 500, async () => {
    const wallets = await rpc(USER_API, 'listWallets', {}, accessToken)
    const list = Array.isArray(wallets) ? wallets : wallets.wallets
    return list.find((w) => w.partyId === partyId)
  })
  if (!wallet.primary) {
    await rpc(USER_API, 'setPrimaryWallet', { partyId }, accessToken)
    log('marked wallet primary')
  }
  log(`gateway adopted wallet party: ${wallet.partyId} (signing: ${wallet.signingProviderId})`)
  writeJson('wallet.json', { partyId, accessToken })
  writeJson('setup-input.json', { wallet: partyId, operator })
}

// createWallet functionality runs straight on the Wallet Gateway JSON-RPC API. It does not go through CIP103 interfaces supported methods, since dApps do not provision wallets. 
async function createWallet() {
  if (EXTERNAL) return createWalletExternal()
  log(`user API: ${USER_API}, network: ${NETWORK_ID}`)
  await provisionLedgerUser(LEDGER_USER)
  const { accessToken } = await rpc(USER_API, 'selfSignedAccessToken', {
    networkId: NETWORK_ID,
    clientId: LEDGER_USER,
  })
  log('obtained self-signed access token')
  await rpc(USER_API, 'addSession', { networkId: NETWORK_ID, origin: DAPP_ORIGIN }, accessToken)
  log('session added')
  const created = await rpc(
    USER_API,
    'createWallet',
    { primary: true, partyHint: 'oz-cip0103-wallet', signingProviderId: 'wallet-kernel' },
    accessToken
  )
  log(`createWallet: ${created.wallet.partyId} (status ${created.wallet.status})`)
  const wallet = await poll('wallet party allocation', 60_000, 500, async () => {
    const wallets = await rpc(USER_API, 'listWallets', {}, accessToken)
    const list = Array.isArray(wallets) ? wallets : wallets.wallets
    return list.find((w) => w.partyId === created.wallet.partyId && w.status === 'allocated')
  })
  log(`wallet party allocated: ${wallet.partyId}`)
  writeJson('wallet.json', { partyId: wallet.partyId, accessToken })
  // Also emit the Daml Script input for the setup phase.
  writeJson('setup-input.json', wallet.partyId)
}

async function dappFlow() {
  const { partyId, accessToken } = readJson('wallet.json')
  const setup = readJson('setup-output.json')

  // CIP-0103 session surface: connects through `connect`, checks connection through `isConnected` and `status`, checks correct network through `getActiveNetwork`. 
  const connect = await rpc(DAPP_API, 'connect', {}, accessToken)
  log(`connect: ${safeJson(connect)}`)
  if (connect.isConnected === false) fail(`gateway session not connected: ${safeJson(connect)}`)
  const alive = await rpc(DAPP_API, 'isConnected', {}, accessToken)
  if (alive.isConnected !== true) fail(`isConnected: ${safeJson(alive)}`)
  const status = await rpc(DAPP_API, 'status', {}, accessToken)
  log(`status: ${safeJson(status)}`)
  const network = await rpc(DAPP_API, 'getActiveNetwork', {}, accessToken)
  if (network.networkId !== NETWORK_ID) fail(`getActiveNetwork returned ${network.networkId}, expected ${NETWORK_ID}`)
  log(`getActiveNetwork: ${network.networkId}`)

  // CIP-0103 account surface: retrieve all parties controlled by this wallet, through `listAccounts`; retrieve the primary account through `getPrimaryAccount`. Primary account is the account that serves as the default, unless some other is specified for execution.
  const accounts = await rpc(DAPP_API, 'listAccounts', {}, accessToken)
  const accountList = Array.isArray(accounts) ? accounts : accounts.accounts
  const mine = accountList.find((a) => a.partyId === partyId)
  if (!mine) fail(`listAccounts does not include wallet party ${partyId}`)
  log(`listAccounts includes wallet party (primary=${mine.primary})`)
  const primaryAccount = await rpc(DAPP_API, 'getPrimaryAccount', {}, accessToken)
  if (primaryAccount.partyId !== partyId || primaryAccount.primary !== true) {
    fail(`getPrimaryAccount returned ${primaryAccount.partyId} (primary=${primaryAccount.primary}), expected wallet party`)
  }
  log('getPrimaryAccount is the wallet party')

  // Baselines: a shared external ledger accumulates state across runs, so all
  // post-settlement checks are deltas against what the wallet sees now. The
  // ledger offset bounds the update stream that the verify phase reads.
  const preHoldings = await acs(accessToken, partyId, T.holding) // Returns the holdings the wallet party sees, as `Holding` interface views.
  const baseline = {
    ledgerEndOffset: await ledgerEnd(accessToken),
    unlockedBalance: unlockedBalance(preHoldings),
    // External mode reuses the wallet party: a run that stopped between its
    // allocation and its settlement leaves a holding locked until the
    // registry's lock expires, and a later run must not count it as its own.
    lockedHoldingCids: preHoldings.filter((h) => !isUnlocked(h)).map((h) => h.contractId),
  }
  const preHoldingCids = new Set(preHoldings.map((h) => h.contractId))
  log(`baselines: ${JSON.stringify(baseline)}`)

  const sse = listenTxChanged(accessToken) // Opens a connection to the Server-Sent Event stream. This stream can be drained later, to look for the events we are interested in.

  // 1. Wallet receives its funding: it accepts the registry's mint offer, a
  //    pending Token Standard V2 transfer instruction from the mint account.
  await exerciseViaGateway(accessToken, partyId, 'mint-offer', T.transferInstruction, setup.mintOfferCid, 'TransferInstruction_Accept', { actors: [partyId], extraArgs: EXTRA_ARGS })
  const minted = await poll('freshly minted wallet holding in ACS', 30_000, 500, async () => { // To demonstrate the flow, the issuer has previously offered a 40 USD mint, waiting to be accepted. The accept above created the holding; find it.
    const hs = await acs(accessToken, partyId, T.holding)
    const fresh = hs.filter((h) => !preHoldingCids.has(h.contractId) && isUnlocked(h) && Number(h.view?.amount ?? 0) === 40)
    return fresh.length > 0 ? fresh : undefined
  })
  const holdingCid = minted[0].contractId
  log(`wallet holding: ${holdingCid}`)

  // 2. Wallet reads the dApp's request through the standard view and funds the
  //    requested allocation through the registry's factory, with the rules
  //    contract (invisible to the wallet) passed as a disclosed contract.
  const requests = await acs(accessToken, partyId, T.allocationRequest)
  const request = requests.find((r) => r.contractId === setup.requestCid)
  if (!request?.view) fail(`wallet does not see the dApp's allocation request ${setup.requestCid}`)
  const requested = request.view.allocations?.[0]
  if (!requested || requested.authorizer?.owner !== partyId) fail(`the request does not name the wallet as authorizer: ${JSON.stringify(request.view)}`)
  log(`wallet sees the dApp's request: settlement ${request.view.settlement.id}, ${request.view.allocations.length} allocation(s)`)
  const disclosure = await rulesDisclosure(await dappLedgerToken(), setup.admin, setup.rulesCid)
  const preAllocations = new Set((await acs(accessToken, partyId, T.allocation)).map((a) => a.contractId))
  await exerciseViaGateway(accessToken, partyId, 'allocate', T.allocationFactory, setup.rulesCid, 'AllocationFactory_Allocate', {
    settlement: request.view.settlement,
    allocation: requested,
    requestedAt: isoNow(),
    inputHoldingCids: [holdingCid],
    extraArgs: EXTRA_ARGS,
    actors: [partyId],
  }, [disclosure])
  const allocations = await poll('wallet allocation in ACS', 30_000, 500, async () => { // Poll the party's allocations until the new one pops up.
    const as = (await acs(accessToken, partyId, T.allocation)).filter((a) => !preAllocations.has(a.contractId))
    return as.length > 0 ? as : undefined
  })
  const walletAllocationCid = allocations[0].contractId
  log(`wallet allocation: ${walletAllocationCid}`)

  // 3. Wallet accepts the dApp's request, which consumes it. Interactive
  //    submission prepares one command per transaction, so this is a
  //    prepareExecute of its own (the Daml rehearsal submits both as one).
  await exerciseViaGateway(accessToken, partyId, 'accept-request', T.allocationRequest, setup.requestCid, 'AllocationRequest_Accept', { actors: [partyId], extraArgs: EXTRA_ARGS })
  const requestsAfter = await acs(accessToken, partyId, T.allocationRequest)
  if (requestsAfter.some((r) => r.contractId === setup.requestCid)) fail('the accepted request is still active in the wallet projection')

  // 4. signMessage: proof of wallet-party key control. Strict locally; in
  // external mode the adopted party signs via the participant, which may not
  // expose message signing - tolerated and recorded as skipped.
  const message = 'oz-cip0103-interop proof-of-party-control'
  let signMessageEvidence
  try {
    const signedMsg = await signMessageViaGateway(accessToken, partyId, message) // Ask the gateway to sign the message, through the CIP103 interface signMessage.
    const keyMatchesPrimary = !primaryAccount.publicKey || signedMsg.publicKey === primaryAccount.publicKey // Check that the publicKey that corresponds to the signed message is the one of the primary account.
    if (!keyMatchesPrimary) fail(`signMessage public key differs from getPrimaryAccount's`)
    if (!verifyEd25519(signedMsg.publicKey, message, signedMsg.signature)) {
      fail('signMessage signature failed Ed25519 verification against the wallet public key')
    }
    log('signMessage: signature verified against the wallet party public key')
    signMessageEvidence = { messageId: signedMsg.messageId, userUrl: signedMsg.userUrl, verified: true }
  } catch (err) {
    if (!EXTERNAL) throw err
    log(`signMessage skipped in external mode: ${err.message}`)
    signMessageEvidence = { skipped: true, reason: err.message }
  }

  // 5. Standardized error path: a doomed command must fail visibly.
  const failedTx = await expectFailedTx(accessToken, partyId, setup.mintOfferCid)

  // Pre-settlement: the wallet's allocation is live, and the change of the
  // allocation is already spendable: 15 of the 40 USD it received.
  const midHoldings = await acs(accessToken, partyId, T.holding)
  const midDelta = unlockedBalance(midHoldings) - baseline.unlockedBalance
  if (Math.abs(midDelta - 15) > 1e-9) fail(`wallet unlocked balance delta before settlement is ${midDelta}, expected +15 (minted 40, locked 25)`)
  if (!midHoldings.some((h) => !isUnlocked(h) && Number(h.view?.amount ?? 0) === 25)) fail('expected the 25 USD locked behind the allocation')

  // SSE frames are delivered asynchronously: the user-API poll above only
  // guarantees each transaction executed, not that its `executed` frame has
  // arrived. Drain the stream until all three frames are in before stopping.
  const collectTxEvents = () =>
    sse.events
      .flatMap((e) => (Array.isArray(e.data) ? e.data : [e.data]))
      .filter((d) => d && typeof d === 'object' && d.status)
      .map((d) => ({ status: d.status, commandId: d.commandId, ...(d.payload ? { payload: d.payload } : {}) }))
  await poll('3 executed txChanged frames', 30_000, 200, () => // Poll until the SSE stream has shown events for all three commands we executed successfully, and collect those events.
    collectTxEvents().filter((e) => e.status === 'executed').length >= 3 ? true : undefined
  )
  await sse.stop()
  const txEvents = collectTxEvents()
  log(`txChanged events observed: ${txEvents.length}`)
  for (const e of txEvents) log(`  ${JSON.stringify(e)}`)

  writeJson('gateway-output.json', { // Write the events to json and other evidence to json.
    walletAllocationCid,
    baseline,
    txChangedEvents: txEvents,
    prepareExecuteUserUrls,
    signMessage: signMessageEvidence,
    failedTx,
  })
  writeJson('settle-input.json', { // Save the allocation id and other necessary info, for the settlement step.
    admin: setup.admin,
    app: setup.app,
    wallet: partyId,
    receiver: setup.receiver,
    rulesCid: setup.rulesCid,
    walletAllocationCid,
    receiverAllocationCid: setup.receiverAllocationCid,
  })
  writeJson('verify-input.json', { // Save balances for the verify input step.
    admin: setup.admin,
    app: setup.app,
    wallet: partyId,
    receiver: setup.receiver,
    baselineWalletBalance: setup.baselineWalletBalance,
    baselineReceiverBalance: setup.baselineReceiverBalance,
    baselineSupply: setup.baselineSupply,
  })
}

async function verifyWalletView() {
  const { partyId, accessToken } = readJson('wallet.json')
  const { baseline, walletAllocationCid } = readJson('gateway-output.json')

  // This function should run after settlement. The wallet reads the standard
  // event stream of its account through the gateway: the settlement emitted an
  // `EventLog_HoldingsChange` on the wallet's account that names the leg the
  // wallet sent. The mint and the allocation emitted events of their own.
  const events = await holdingsChanges(accessToken, partyId, baseline.ledgerEndOffset)
  const mineEvents = events.filter((e) => e.account?.owner === partyId)
  const settled = mineEvents.filter((e) => (e.transferLegSides ?? []).some((s) => s.transferLegId === `${REF}-leg` && s.side === 'SenderSide'))
  if (settled.length !== 1) {
    fail(`wallet sees ${settled.length} settlement event(s) on its account via gateway ledgerApi, expected 1 (${mineEvents.length} holdings-change event(s) in total)`)
  }
  log(`wallet sees the settlement's holdings-change event on its account via gateway ledgerApi (${mineEvents.length} event(s) since the baseline)`)

  // The allocation is consumed, and the wallet holds its change unlocked.
  const allocations = await acs(accessToken, partyId, T.allocation)
  if (allocations.some((a) => a.contractId === walletAllocationCid)) fail('the settled allocation is still active in the wallet projection')
  const holdings = await acs(accessToken, partyId, T.holding)
  const baselineLocked = new Set(baseline.lockedHoldingCids ?? [])
  const newlyLocked = holdings.filter((h) => !isUnlocked(h) && !baselineLocked.has(h.contractId))
  if (newlyLocked.length > 0) fail(`${newlyLocked.length} wallet holding(s) locked by this run are still locked after settlement`)
  const delta = unlockedBalance(holdings) - baseline.unlockedBalance
  if (Math.abs(delta - 15) > 1e-9) fail(`wallet balance delta is ${delta}, expected +15 (minted 40, sent 25)`)
  log(`wallet balance delta is +15.0 as expected, with nothing of this run locked`)

  // CIP-0103 session teardown: disconnect, then confirm the dApp is no longer
  // connected. Last step, after every gateway read above.
  await rpc(DAPP_API, 'disconnect', {}, accessToken)
  const after = await rpc(DAPP_API, 'isConnected', {}, accessToken)
  if (after.isConnected !== false) fail(`isConnected after disconnect: ${safeJson(after)}`)
  log('disconnect: session closed, isConnected now false')

  log('wallet-view verification passed')
}

const command = process.argv[2]
const commands = {
  'create-wallet': createWallet,
  'dapp-flow': dappFlow,
  'verify-wallet-view': verifyWalletView,
  'setup-external': setupExternal,
  'settle-external': settleExternal,
  'verify-external': verifyExternal,
}
if (!commands[command]) {
  console.error(`usage: harness.mjs <${Object.keys(commands).join('|')}>`)
  process.exit(2)
}
commands[command]().catch((err) => fail(err.stack ?? String(err)))
