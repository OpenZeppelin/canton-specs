#!/usr/bin/env node
// CIP-0103 third-party interop harness: drives the OpenZeppelin CIP-0112
// settlement surface through the Canton Wallet Gateway (the CIP-0103
// implementation formerly known as Splice Wallet Kernel).
//
// The wallet user is an externally-signed party created and held by the
// gateway (built-in `wallet-kernel` Ed25519 signing driver). Every wallet-side
// ledger action goes through the gateway's CIP-0103 dApp JSON-RPC API
// (`prepareExecute` + `txChanged` + `ledgerApi`); transaction approval uses the
// gateway's user JSON-RPC API (`sign` + `execute`), i.e. the same calls the
// gateway's own approve UI makes. No direct Ledger API access is used for the
// wallet party anywhere in this file.
//
// Subcommands (orchestrated by scripts/wallet-gateway-cip0103-interop.sh):
//   create-wallet      create session + externally-signed wallet party
//   dapp-flow          connect, accept offers/request, build the allocation
//   verify-wallet-view assert the wallet's post-settlement projection
//
// Experiment-only; no conformance or production claim.

import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { join } from 'node:path'

const GATEWAY = process.env.OZ_GATEWAY_URL ?? 'http://127.0.0.1:3030'
const USER_API = `${GATEWAY}/api/v0/user`
const DAPP_API = `${GATEWAY}/api/v0/dapp`
const JSON_API = process.env.OZ_JSON_API_URL ?? 'http://127.0.0.1:7575'
const NETWORK_ID = process.env.OZ_GATEWAY_NETWORK_ID ?? 'canton:local-sandbox'
const WORK_DIR = process.env.OZ_INTEROP_WORK_DIR ?? '.cache/wallet-gateway-interop'
const LEDGER_USER = 'oz-cip0103-interop'

const PKG_INTEROP = '#oz-experimental-cip-interop-exemplar'
const PKG_SETTLEMENT = '#oz-experimental-cip112-settlement'
const MOD_GATEWAY = 'OpenZeppelin.Experimental.Interop.WalletGateway'
const MOD_ENGINE = 'OpenZeppelin.Experimental.Settlement.Cip112'
const T = {
  holdingOffer: `${PKG_INTEROP}:${MOD_GATEWAY}:GatewayHoldingOffer`,
  allocationOffer: `${PKG_INTEROP}:${MOD_GATEWAY}:GatewayAllocationOffer`,
  allocationRequest: `${PKG_SETTLEMENT}:${MOD_ENGINE}:AllocationRequest`,
  toyHolding: `${PKG_SETTLEMENT}:${MOD_ENGINE}:ToyHolding`,
  allocation: `${PKG_SETTLEMENT}:${MOD_ENGINE}:Allocation`,
  receipt: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementReceipt`,
  eventLog: `${PKG_SETTLEMENT}:${MOD_ENGINE}:SettlementEventLogEntry`,
}

let rpcId = 0
const log = (...args) => console.log('[harness]', ...args)

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
    throw new Error(`${method}: JSON-RPC error ${body.error.code}: ${body.error.message} ${JSON.stringify(body.error.data ?? '')}`)
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

// Query the wallet party's active contracts for one template via the gateway.
async function acs(token, party, templateId) {
  const end = await ledgerApi(token, 'get', '/v2/state/ledger-end')
  const offset = end?.offset ?? end?.body?.offset
  if (offset === undefined) throw new Error(`ledger-end gave no offset: ${JSON.stringify(end)}`)
  const request = {
    filter: {
      filtersByParty: {
        [party]: {
          cumulative: [
            {
              identifierFilter: {
                TemplateFilter: {
                  value: { templateId, includeCreatedEventBlob: false },
                },
              },
            },
          ],
        },
      },
    },
    verbose: false,
    activeAtOffset: offset,
  }
  const res = await ledgerApi(token, 'post', '/v2/state/active-contracts', request)
  const items = Array.isArray(res) ? res : (res?.body ?? [])
  const contracts = []
  for (const item of items) {
    const entry = item?.contractEntry?.JsActiveContract ?? item?.contractEntry?.activeContract
    const ev = entry?.createdEvent
    if (ev) contracts.push({ contractId: ev.contractId, payload: ev.createArgument ?? ev.createArguments })
  }
  return contracts
}

// --- dApp command submission + user-side approval ----------------------------

async function exerciseViaGateway(token, party, label, templateId, contractId, choice, choiceArgument) {
  const commandId = `oz-cip0103-interop-${label}`
  log(`prepareExecute ${choice} (commandId=${commandId})`)
  await rpc(
    DAPP_API,
    'prepareExecute',
    {
      commandId,
      commands: [{ ExerciseCommand: { templateId, contractId, choice, choiceArgument } }],
    },
    token
  )

  // The remote gateway parks the prepared transaction for user approval.
  // Approve it programmatically through the user API, exactly as the
  // gateway's own approve page does: sign, then execute.
  const tx = await poll(`pending transaction ${commandId}`, 30_000, 300, async () => {
    const { transactions } = await rpc(USER_API, 'listTransactions', {}, token)
    return transactions.find((t) => t.commandId === commandId && t.status === 'pending')
  })
  log(`sign transaction ${tx.id}`)
  const signed = await rpc(USER_API, 'sign', { transactionId: tx.id, partyId: party }, token)
  if (signed.status !== 'signed') {
    throw new Error(`sign returned status ${signed.status}: ${JSON.stringify(signed)}`)
  }
  log(`execute transaction ${tx.id}`)
  await rpc(
    USER_API,
    'execute',
    { signature: signed.signature, signedBy: signed.signedBy, transactionId: tx.id, partyId: party },
    token
  )
  const done = await poll(`transaction ${commandId} executed`, 30_000, 300, async () => {
    const transaction = await rpc(USER_API, 'getTransaction', { transactionId: tx.id }, token)
    if (transaction.status === 'failed') throw new Error(`transaction failed: ${JSON.stringify(transaction)}`)
    return transaction.status === 'executed' ? transaction : undefined
  })
  log(`executed ${choice} (transaction ${done.id})`)
  return done
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

// --- subcommands -------------------------------------------------------------

// Provision the wallet user's ledger user on the participant. This is
// admin-side IAM provisioning against the sandbox, NOT part of the wallet
// surface under test; on a real network the validator operator does this.
async function ensureLedgerUser(userId) {
  const res = await fetch(`${JSON_API}/v2/users`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
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

async function createWallet() {
  log(`user API: ${USER_API}, network: ${NETWORK_ID}`)
  await ensureLedgerUser(LEDGER_USER)
  const { accessToken } = await rpc(USER_API, 'selfSignedAccessToken', {
    networkId: NETWORK_ID,
    clientId: LEDGER_USER,
  })
  log('obtained self-signed access token')
  await rpc(USER_API, 'addSession', { networkId: NETWORK_ID }, accessToken)
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

  // CIP-0103 session surface.
  const connect = await rpc(DAPP_API, 'connect', {}, accessToken)
  log(`connect: ${JSON.stringify(connect)}`)
  if (connect.isConnected === false) fail(`gateway session not connected: ${JSON.stringify(connect)}`)
  const status = await rpc(DAPP_API, 'status', {}, accessToken)
  log(`status: ${JSON.stringify(status)}`)
  const accounts = await rpc(DAPP_API, 'listAccounts', {}, accessToken)
  const accountList = Array.isArray(accounts) ? accounts : accounts.accounts
  const mine = accountList.find((a) => a.partyId === partyId)
  if (!mine) fail(`listAccounts does not include wallet party ${partyId}`)
  log(`listAccounts includes wallet party (primary=${mine.primary})`)

  const sse = listenTxChanged(accessToken)

  // 1. Wallet receives its funding holding (propose-accept mint).
  await exerciseViaGateway(accessToken, partyId, 'holding-offer', T.holdingOffer, setup.holdingOfferCid, 'GatewayHoldingOffer_Accept', {})
  const holdings = await poll('wallet ToyHolding in ACS', 30_000, 500, async () => {
    const hs = await acs(accessToken, partyId, T.toyHolding)
    return hs.length > 0 ? hs : undefined
  })
  const holdingCid = holdings[0].contractId
  log(`wallet holding: ${holdingCid}`)

  // 2. Wallet accepts the app's CIP-0103 allocation request.
  await exerciseViaGateway(accessToken, partyId, 'allocation-request', T.allocationRequest, setup.requestCid, 'AllocationRequest_Accept', { actors: [partyId] })

  // 3. Wallet funds and accepts the sender-side allocation.
  await exerciseViaGateway(accessToken, partyId, 'allocation-offer', T.allocationOffer, setup.allocationOfferCid, 'GatewayAllocationOffer_Accept', { holdingCids: [holdingCid] })
  const allocations = await poll('wallet Allocation in ACS', 30_000, 500, async () => {
    const as = await acs(accessToken, partyId, T.allocation)
    return as.length > 0 ? as : undefined
  })
  const walletAllocationCid = allocations[0].contractId
  log(`wallet allocation: ${walletAllocationCid}`)

  // Pre-settlement: the wallet must not yet see any receipt.
  const preReceipts = await acs(accessToken, partyId, T.receipt)
  if (preReceipts.length !== 0) fail(`expected 0 receipts before settlement, saw ${preReceipts.length}`)

  await sse.stop()
  const rawEvents = sse.events.flatMap((e) => (Array.isArray(e.data) ? e.data : [e.data]))
  const txEvents = rawEvents
    .filter((d) => d && typeof d === 'object' && d.status)
    .map((d) => ({ status: d.status, commandId: d.commandId, ...(d.payload ? { payload: d.payload } : {}) }))
  log(`txChanged events observed: ${txEvents.length}`)
  for (const e of txEvents) log(`  ${JSON.stringify(e)}`)
  const executedEvents = txEvents.filter((e) => e.status === 'executed')
  if (executedEvents.length < 3) fail(`expected >= 3 executed txChanged events, saw ${executedEvents.length}`)

  writeJson('gateway-output.json', { walletAllocationCid, txChangedEvents: txEvents })
  writeJson('settle-input.json', {
    admin: setup.admin,
    app: setup.app,
    wallet: partyId,
    receiver: setup.receiver,
    factoryCid: setup.factoryCid,
    walletAllocationCid,
    receiverAllocationCid: setup.receiverAllocationCid,
  })
  writeJson('verify-input.json', {
    admin: setup.admin,
    app: setup.app,
    wallet: partyId,
    receiver: setup.receiver,
  })
}

async function verifyWalletView() {
  const { partyId, accessToken } = readJson('wallet.json')

  const receipts = await acs(accessToken, partyId, T.receipt)
  if (receipts.length < 1) fail(`wallet sees ${receipts.length} settlement receipts, expected >= 1`)
  log(`wallet sees ${receipts.length} settlement receipt(s) via gateway ledgerApi`)

  const entries = await acs(accessToken, partyId, T.eventLog)
  if (entries.length < 1) fail(`wallet sees ${entries.length} event log entries, expected >= 1`)
  log(`wallet sees ${entries.length} settlement event log entrie(s)`)

  const holdings = await acs(accessToken, partyId, T.toyHolding)
  const unlocked = holdings.filter((h) => !h.payload?.lock)
  const change = unlocked.reduce((acc, h) => acc + Number(h.payload?.amount ?? 0), 0)
  if (change !== 15) fail(`wallet change balance is ${change}, expected 15`)
  log(`wallet change holding is 15.0 as expected`)

  log('wallet-view verification passed')
}

const command = process.argv[2]
const commands = {
  'create-wallet': createWallet,
  'dapp-flow': dappFlow,
  'verify-wallet-view': verifyWalletView,
}
if (!commands[command]) {
  console.error(`usage: harness.mjs <${Object.keys(commands).join('|')}>`)
  process.exit(2)
}
commands[command]().catch((err) => fail(err.stack ?? String(err)))
